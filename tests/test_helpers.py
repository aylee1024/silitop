"""Tests for UNIT E: helper-boundary v1 protocol.

The Swift helpers emit a version header on the first stdout line. The Python
parsers (read_hid_temps, read_fan_speeds) implement a three-state contract:
  None  - helper broken (missing path, crash, version mismatch, decode error)
  {}/[] - helper succeeded, confirmed empty (e.g., fanless MacBook Air)
  data  - measured readings

Tests stub subprocess.check_output to simulate Swift helper output without
requiring the real binaries.
"""
import importlib.util
import os
import pathlib
import subprocess
import sys
import unittest
from importlib.machinery import SourceFileLoader
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
_loader = SourceFileLoader("SILITOP", str(ROOT / "silitop"))
_spec = importlib.util.spec_from_loader("SILITOP", _loader)
SILITOP = importlib.util.module_from_spec(_spec)
sys.modules["SILITOP"] = SILITOP
_loader.exec_module(SILITOP)


def _patched_helper(stdout_text, *, raises=None):
    """Context manager-ish helper: returns a check_output side_effect that
    returns stdout_text when called, or raises the given exception."""
    def side(args, **kwargs):
        if raises is not None:
            raise raises
        return stdout_text
    return side


class TempsProtocolTests(unittest.TestCase):
    """read_hid_temps parses v1 header, returns None on mismatch, {} on
    confirmed-empty, dict on measured."""

    def _call(self, stdout=None, raises=None):
        with mock.patch.object(SILITOP.subprocess, "check_output",
                               side_effect=_patched_helper(stdout, raises=raises)):
            return SILITOP.read_hid_temps("/fake/silitop-temps")

    def test_none_when_helper_missing(self):
        self.assertIsNone(SILITOP.read_hid_temps(None))

    def test_none_when_subprocess_raises(self):
        self.assertIsNone(self._call(raises=FileNotFoundError("fake")))

    def test_none_when_helper_times_out(self):
        self.assertIsNone(self._call(
            raises=subprocess.TimeoutExpired(cmd="fake", timeout=1.5)))

    def test_none_when_helper_nonzero_exit(self):
        # CalledProcessError is a SubprocessError; caught by _run_helper.
        self.assertIsNone(self._call(
            raises=subprocess.CalledProcessError(2, "fake")))

    def test_none_when_header_missing(self):
        # No protocol header -> version mismatch -> broken.
        self.assertIsNone(self._call(stdout="PMU tdie0|55.0\n"))

    def test_none_when_header_wrong_version(self):
        self.assertIsNone(self._call(
            stdout="silitop-temps v2\nSTATUS|ok\nPMU tdie0|55.0\n"))

    def test_empty_dict_when_no_sensors(self):
        # Header present but no sensor lines; STATUS|no_sensors_found is the
        # explicit "I tried and found nothing" signal.
        out = "silitop-temps v1\nSTATUS|no_sensors_found\n"
        self.assertEqual(self._call(stdout=out), {})

    def test_parses_sensor_lines(self):
        out = ("silitop-temps v1\n"
               "STATUS|ok\n"
               "PMU tdie0|45.3\n"
               "PMU tdie1|48.1\n"
               "NAND CH0 temp|38.0\n")
        result = self._call(stdout=out)
        self.assertEqual(result, {
            "PMU tdie0": 45.3,
            "PMU tdie1": 48.1,
            "NAND CH0 temp": 38.0,
        })

    def test_drops_malformed_lines_silently(self):
        out = ("silitop-temps v1\n"
               "STATUS|ok\n"
               "GoodSensor|42.0\n"
               "BadSensor|not_a_number\n"
               "JustAName\n"
               "AnotherGood|50.0\n")
        result = self._call(stdout=out)
        self.assertEqual(result, {"GoodSensor": 42.0, "AnotherGood": 50.0})

    def test_drops_nan_and_inf(self):
        out = ("silitop-temps v1\n"
               "STATUS|ok\n"
               "NaN Sensor|nan\n"
               "Inf Sensor|inf\n"
               "Real|55.5\n")
        result = self._call(stdout=out)
        self.assertEqual(result, {"Real": 55.5})


class FansProtocolTests(unittest.TestCase):
    """read_fan_speeds implements the same three-state contract. The fan
    latch only fires on confirmed STATUS|fanless, not on broken-helper
    transients."""

    def _call(self, stdout=None, raises=None):
        with mock.patch.object(SILITOP.subprocess, "check_output",
                               side_effect=_patched_helper(stdout, raises=raises)):
            return SILITOP.read_fan_speeds("/fake/silitop-fans")

    def test_none_when_helper_missing(self):
        self.assertIsNone(SILITOP.read_fan_speeds(None))

    def test_none_when_subprocess_raises(self):
        self.assertIsNone(self._call(raises=OSError("fake")))

    def test_none_when_header_missing(self):
        self.assertIsNone(self._call(stdout="FAN0|2000|6500\n"))

    def test_none_when_smc_unavailable(self):
        # The Swift helper emits STATUS|smc_unavailable + exit 2 when
        # AppleSMC cannot be opened. Python sees this as broken, not
        # confirmed-fanless: the next slow-poll cycle retries.
        out = "silitop-fans v1\nSTATUS|smc_unavailable\n"
        self.assertIsNone(self._call(stdout=out))

    def test_empty_list_for_confirmed_fanless(self):
        # MacBook Air: FNum=0 -> STATUS|fanless -> [] -> caller latches.
        out = "silitop-fans v1\nSTATUS|fanless\n"
        self.assertEqual(self._call(stdout=out), [])

    def test_parses_fan_lines(self):
        out = ("silitop-fans v1\n"
               "STATUS|ok\n"
               "FAN0|1800|6500\n"
               "FAN1|1850|6500\n")
        result = self._call(stdout=out)
        self.assertEqual(result, [
            {"rpm": 1800.0, "max_rpm": 6500.0},
            {"rpm": 1850.0, "max_rpm": 6500.0},
        ])

    def test_drops_lines_with_zero_max_rpm(self):
        # Sanity gate: max_rpm <= 0 means the F<i>Mx read failed; drop the
        # line entirely rather than fabricating a percentage.
        out = ("silitop-fans v1\n"
               "STATUS|ok\n"
               "FAN0|1800|0\n"
               "FAN1|1850|6500\n")
        result = self._call(stdout=out)
        self.assertEqual(result, [{"rpm": 1850.0, "max_rpm": 6500.0}])

    def test_drops_nan_inf_rpm(self):
        out = ("silitop-fans v1\n"
               "STATUS|ok\n"
               "FAN0|nan|6500\n"
               "FAN1|inf|6500\n"
               "FAN2|1900|6500\n")
        result = self._call(stdout=out)
        self.assertEqual(result, [{"rpm": 1900.0, "max_rpm": 6500.0}])


class SocInfoFallbackTests(unittest.TestCase):
    """get_soc_info returns None sentinels (not guessed 4+4 defaults) when
    every detection path fails, and sets tier_labels_detected accordingly."""

    def test_total_failure_yields_none_topology(self):
        def boom(args, **kwargs):
            raise FileNotFoundError(args)
        with mock.patch.object(SILITOP.subprocess, "check_output",
                               side_effect=boom):
            info = SILITOP.get_soc_info()
        self.assertIsNone(info["name"])
        self.assertIsNone(info["p_core_count"])
        self.assertIsNone(info["e_core_count"])
        self.assertIsNone(info["gpu_core_count"])
        self.assertFalse(info["tier_labels_detected"])
        # TDP fallback bucket still populated (base).
        self.assertEqual(info["cpu_max_power"], 20)

    def test_chip_line_used_when_sysctl_brand_string_fails(self):
        """Audit #15: on sandboxed hosts sysctl machdep.cpu.brand_string can
        return "Operation not permitted" while system_profiler still emits
        the Chip: line. The new fallback picks up Chip: so the M5 Pro lands
        in the Pro TDP bucket instead of the base bucket."""
        def fake(args, **kwargs):
            if args and os.path.basename(args[0]) == "sysctl":
                # First call: machdep.cpu.brand_string. Raise as if sandboxed.
                raise subprocess.CalledProcessError(1, args)
            if args and os.path.basename(args[0]) == "system_profiler":
                return ("Hardware:\n"
                        "    Hardware Overview:\n"
                        "      Chip: Apple M5 Pro\n"
                        "      Total Number of Cores: 18 (6 Super and 12 Performance)\n")
            return ""
        with mock.patch.object(SILITOP.subprocess, "check_output",
                               side_effect=fake):
            info = SILITOP.get_soc_info()
        self.assertEqual(info["name"], "Apple M5 Pro")
        self.assertEqual(info["cpu_max_power"], 30)  # Pro bucket, not base
        self.assertEqual(info["p_core_count"], 6)
        self.assertEqual(info["e_core_count"], 12)
        self.assertTrue(info["tier_labels_detected"])


class IsEfficiencyTests(unittest.TestCase):
    """_is_efficiency must be case-insensitive (audit #14: M1-M4 bug)."""

    def test_m5_uppercase_matches(self):
        self.assertTrue(SILITOP._is_efficiency("P-Cluster", "P"))
        self.assertFalse(SILITOP._is_efficiency("S-Cluster", "P"))

    def test_m1_m4_lowercase_slow_prefix_still_matches(self):
        # The bug: system_profiler reported lower-case 'efficiency'/'e' on
        # M1-M4 while powermetrics cluster names start with upper-case 'E'.
        self.assertTrue(SILITOP._is_efficiency("E-Cluster", "e"))
        self.assertTrue(SILITOP._is_efficiency("e-cluster", "E"))

    def test_empty_name_returns_false(self):
        self.assertFalse(SILITOP._is_efficiency("", "E"))
        self.assertFalse(SILITOP._is_efficiency(None, "E"))

    def test_empty_prefix_returns_false(self):
        self.assertFalse(SILITOP._is_efficiency("E-Cluster", ""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
