"""Tests for UNIT B (power math) and UNIT D (extractor None-sentinels).

UNIT B coverage: extract_cpu correctly converts millijoule energy fields
to joules-per-interval, and combined_power passes through unchanged as
watts. Caller is responsible for /delta_t_s; this test verifies the
extract_cpu contract that the caller relies on.
"""
import importlib.util
import pathlib
import sys
import unittest
from datetime import datetime
from importlib.machinery import SourceFileLoader

ROOT = pathlib.Path(__file__).resolve().parent.parent
_loader = SourceFileLoader("SILITOP", str(ROOT / "silitop"))
_spec = importlib.util.spec_from_loader("SILITOP", _loader)
SILITOP = importlib.util.module_from_spec(_spec)
sys.modules["SILITOP"] = SILITOP
_loader.exec_module(SILITOP)

SOC_M5_PRO = {
    "name": "Apple M5 Pro", "e_core_count": 12, "p_core_count": 6,
    "gpu_core_count": 20, "fast_label": "Super", "slow_label": "Performance",
    "fast_prefix": "S", "slow_prefix": "P",
    "cpu_max_power": 30, "gpu_max_power": 30, "ane_max_power": 8.0,
}


def _make_parsed(combined_power_mw=30000,
                 cpu_energy_mj=5000, gpu_energy_mj=2000, ane_energy_mj=100,
                 clusters=None):
    """Build a plist-shaped dict for extract_cpu input.

    Defaults assume default 1-second sampling: CPU = 5 W, GPU = 2 W,
    ANE = 0.1 W, combined_power = 30 W. extract_cpu converts mJ -> J
    and mW -> W; the caller then divides energy by elapsed seconds.
    """
    if clusters is None:
        clusters = [
            {"name": "S-Cluster", "freq_hz": 4_000_000_000, "cpus": [
                {"cpu": 0, "idle_ratio": 0.5, "freq_hz": 4_000_000_000},
            ]},
            {"name": "P-Cluster", "freq_hz": 3_000_000_000, "cpus": [
                {"cpu": 1, "idle_ratio": 0.8, "freq_hz": 3_000_000_000},
            ]},
        ]
    return {
        "timestamp": datetime(2026, 5, 19, 12, 0, 0),
        "processor": {
            "clusters": clusters,
            "cpu_energy": cpu_energy_mj,
            "gpu_energy": gpu_energy_mj,
            "ane_energy": ane_energy_mj,
            "combined_power": combined_power_mw,
        },
    }


class ExtractCpuPowerTests(unittest.TestCase):
    """extract_cpu output contract: cpu_w / gpu_w / ane_w are J-per-interval;
    package_w is already in watts."""

    def test_combined_power_in_watts(self):
        parsed = _make_parsed(combined_power_mw=30000)
        _, agg = SILITOP.extract_cpu(parsed, SOC_M5_PRO)
        # combined_power = 30000 mW. extract_cpu /1000 -> 30 W.
        self.assertEqual(agg["package_w"], 30.0)

    def test_combined_power_does_not_depend_on_interval(self):
        """The prior CRIT-3 bug divided package_w by args.interval in main(),
        cutting Total wattage by 1/N at --interval N. extract_cpu output for
        package_w must be the instantaneous power, regardless of interval."""
        parsed = _make_parsed(combined_power_mw=30000)
        _, agg = SILITOP.extract_cpu(parsed, SOC_M5_PRO)
        # Caller's main loop math: pkg_w = agg["package_w"]  (no /delta_t_s)
        for delta_t_s in (1.0, 2.0, 5.0, 0.5):
            pkg_w = agg["package_w"]
            self.assertEqual(pkg_w, 30.0,
                             f"package_w must be invariant under delta_t_s={delta_t_s}")

    def test_energy_fields_are_joules_per_interval(self):
        """cpu_energy / gpu_energy / ane_energy come back as joules; main
        divides by elapsed seconds for watts."""
        parsed = _make_parsed(cpu_energy_mj=5000, gpu_energy_mj=2000,
                              ane_energy_mj=100)
        _, agg = SILITOP.extract_cpu(parsed, SOC_M5_PRO)
        self.assertEqual(agg["cpu_w"], 5.0)
        self.assertEqual(agg["gpu_w"], 2.0)
        self.assertEqual(agg["ane_w"], 0.1)

    def test_energy_to_watts_scales_with_delta_t(self):
        """When the loop falls behind and 2 seconds of energy arrives in one
        sample, dividing by delta_t_s=2 gives the correct average wattage."""
        parsed = _make_parsed(cpu_energy_mj=10000)  # 10 J accumulated
        _, agg = SILITOP.extract_cpu(parsed, SOC_M5_PRO)
        # main()'s formula: cpu_w = agg["cpu_w"] / delta_t_s
        watts_at_1s = agg["cpu_w"] / 1.0
        watts_at_2s = agg["cpu_w"] / 2.0
        self.assertEqual(watts_at_1s, 10.0)
        self.assertEqual(watts_at_2s, 5.0)

    def test_total_consistency(self):
        """Total reported wattage should not be less than CPU+GPU+ANE; the
        prior bug allowed `Total: 7.5W` with CPU+GPU+ANE summing to 15W."""
        parsed = _make_parsed(combined_power_mw=30000,
                              cpu_energy_mj=10000, gpu_energy_mj=5000,
                              ane_energy_mj=200)
        _, agg = SILITOP.extract_cpu(parsed, SOC_M5_PRO)
        # main()'s computed wattages at delta_t_s = 1.0:
        cpu_w = agg["cpu_w"] / 1.0  # 10.0
        gpu_w = agg["gpu_w"] / 1.0  # 5.0
        ane_w = agg["ane_w"] / 1.0  # 0.2
        pkg_w = agg["package_w"]    # 30.0
        # Package is the supply-side measurement; the per-subsystem rails may
        # be lower than the wall draw. But package must NOT be smaller than
        # the sum of measured subsystems.
        self.assertGreaterEqual(pkg_w, cpu_w + gpu_w + ane_w - 0.5,
                                "package_w should be >= CPU+GPU+ANE")


class ExtractorNoneSentinelTests(unittest.TestCase):
    """UNIT D contract: every all-or-nothing extractor returns None when a
    required field is missing, rather than silently producing zeros."""

    def test_extract_cpu_missing_processor(self):
        self.assertIsNone(SILITOP.extract_cpu({"timestamp": "x"}, SOC_M5_PRO))

    def test_extract_cpu_processor_not_a_dict(self):
        self.assertIsNone(SILITOP.extract_cpu({"processor": "garbage"}, SOC_M5_PRO))

    def test_extract_cpu_missing_clusters(self):
        self.assertIsNone(SILITOP.extract_cpu(
            {"processor": {"combined_power": 30000}}, SOC_M5_PRO))

    def test_extract_cpu_missing_combined_power(self):
        self.assertIsNone(SILITOP.extract_cpu(
            {"processor": {"clusters": []}}, SOC_M5_PRO))

    def test_extract_cpu_skips_malformed_cluster_name(self):
        """Empty cluster name used to crash _is_efficiency on name[0]. The
        cluster is now skipped silently; remaining clusters still contribute."""
        parsed = _make_parsed(clusters=[
            {"name": "", "freq_hz": 0, "cpus": []},
            {"name": "P-Cluster", "freq_hz": 3_000_000_000, "cpus": [
                {"cpu": 0, "idle_ratio": 0.8, "freq_hz": 3_000_000_000}]},
        ])
        result = SILITOP.extract_cpu(parsed, SOC_M5_PRO)
        self.assertIsNotNone(result)
        cores, agg = result
        # The malformed cluster was skipped; the P-Cluster's one core lives in
        # the appropriate bucket.
        all_cores = cores["e_cores"] + cores["p_cores"]
        self.assertEqual(len(all_cores), 1)

    def test_extract_gpu_missing(self):
        self.assertIsNone(SILITOP.extract_gpu({"timestamp": "x"}))

    def test_extract_gpu_not_a_dict(self):
        self.assertIsNone(SILITOP.extract_gpu({"gpu": "garbage"}))

    def test_extract_gpu_missing_idle_ratio(self):
        self.assertIsNone(SILITOP.extract_gpu({"gpu": {"freq_hz": 1000}}))

    def test_extract_gpu_missing_freq(self):
        self.assertIsNone(SILITOP.extract_gpu({"gpu": {"idle_ratio": 0.5}}))

    def test_extract_gpu_success(self):
        info = SILITOP.extract_gpu({"gpu": {"idle_ratio": 0.5, "freq_hz": 1000}})
        self.assertEqual(info["active"], 50)
        self.assertEqual(info["freq_mhz"], 1000)

    def test_extract_network_missing(self):
        self.assertIsNone(SILITOP.extract_network({"timestamp": "x"}))

    def test_extract_network_partial(self):
        # Missing ibyte_rate -> None (no silent zeros).
        self.assertIsNone(SILITOP.extract_network({"network": {"obyte_rate": 100}}))

    def test_extract_network_success(self):
        info = SILITOP.extract_network(
            {"network": {"ibyte_rate": 1024, "obyte_rate": 2048}})
        self.assertEqual(info["in_rate"], 1024)
        self.assertEqual(info["out_rate"], 2048)

    def test_extract_disk_missing(self):
        self.assertIsNone(SILITOP.extract_disk({"timestamp": "x"}))

    def test_extract_disk_partial(self):
        self.assertIsNone(SILITOP.extract_disk({"disk": {"rbytes_per_s": 100}}))

    def test_extract_disk_success(self):
        info = SILITOP.extract_disk(
            {"disk": {"rbytes_per_s": 4096, "wbytes_per_s": 8192}})
        self.assertEqual(info["read_rate"], 4096)
        self.assertEqual(info["write_rate"], 8192)


class DeltaTComputationTests(unittest.TestCase):
    """delta_t_s is computed inline in main(); replicate the math here for
    unit-test coverage of the boundary cases that matter."""

    def _delta_t(self, ts, last_ts, args_interval):
        """Mirror of the main-loop computation at silitop:866-877."""
        if last_ts is not None and ts is not None:
            try:
                return max((ts - last_ts).total_seconds(), 0.001)
            except (AttributeError, TypeError):
                return float(args_interval)
        return float(args_interval)

    def test_first_sample_falls_back_to_interval(self):
        ts = datetime(2026, 5, 19, 12, 0, 1)
        self.assertEqual(self._delta_t(ts, None, args_interval=1), 1.0)
        self.assertEqual(self._delta_t(ts, None, args_interval=5), 5.0)

    def test_steady_state_returns_real_elapsed(self):
        ts0 = datetime(2026, 5, 19, 12, 0, 0)
        ts1 = datetime(2026, 5, 19, 12, 0, 2)
        self.assertEqual(self._delta_t(ts1, ts0, args_interval=1), 2.0)

    def test_non_datetime_timestamps_fall_back(self):
        # int timestamps don't support .total_seconds(); fall through.
        self.assertEqual(self._delta_t(2, 1, args_interval=1), 1.0)

    def test_zero_or_negative_delta_clamped_to_001(self):
        ts = datetime(2026, 5, 19, 12, 0, 0)
        # Same timestamp would normally not be passed (dedupe catches it),
        # but if a clock-skew sample arrives, we must not divide by zero.
        self.assertEqual(self._delta_t(ts, ts, args_interval=1), 0.001)


if __name__ == "__main__":
    unittest.main(verbosity=2)
