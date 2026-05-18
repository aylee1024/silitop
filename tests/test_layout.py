import importlib.util
from importlib.machinery import SourceFileLoader
from pathlib import Path
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
LOADER = SourceFileLoader("silitop_module", str(ROOT / "silitop"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
SILITOP = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(SILITOP)


class FakeWindow:
    def __init__(self, height, width):
        self.height = height
        self.width = width
        self.rows = [[" "] * width for _ in range(height)]

    def getmaxyx(self):
        return self.height, self.width

    def addstr(self, y, x, s, attr=0):
        if not (0 <= y < self.height):
            raise SILITOP.curses.error()
        for idx, ch in enumerate(s):
            col = x + idx
            if 0 <= col < self.width:
                self.rows[y][col] = ch

    def render(self, y):
        return "".join(self.rows[y])


class LayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._orig_color_pair = SILITOP.curses.color_pair
        cls._orig_a_bold = SILITOP.curses.A_BOLD
        cls._orig_a_dim = SILITOP.curses.A_DIM
        SILITOP.curses.color_pair = lambda _pair: 0
        SILITOP.curses.A_BOLD = 0
        SILITOP.curses.A_DIM = 0

    @classmethod
    def tearDownClass(cls):
        SILITOP.curses.color_pair = cls._orig_color_pair
        SILITOP.curses.A_BOLD = cls._orig_a_bold
        SILITOP.curses.A_DIM = cls._orig_a_dim

    def assert_drawn_within(self, row, start, width):
        end = start + width
        self.assertEqual(row[:start].strip(), "")
        self.assertEqual(row[end:].strip(), "")

    def test_compute_bar_layout_clamps_and_never_overlaps(self):
        cases = [
            (24, 145, "P0 ", " 100% 960M"),
            (6, 145, "CPU ", " 100%"),
        ]
        for width, pct, label, suffix in cases:
            with self.subTest(width=width, pct=pct, label=label, suffix=suffix):
                layout = SILITOP.compute_bar_layout(width, pct, label=label, suffix=suffix)
                self.assertEqual(layout["pct"], 100)
                self.assertLessEqual(layout["label_span"][1], layout["bar_span"][0])
                self.assertLessEqual(layout["bar_span"][1], layout["suffix_span"][0])
                self.assertLessEqual(layout["suffix_span"][1], width)
                self.assertEqual(
                    layout["fill_width"] + layout["empty_width"],
                    layout["bar_width"],
                )

    def test_core_row_suffix_stays_intact_at_99_100_and_over_100(self):
        cases = [
            (99, 960, "99% 960M"),
            (100, 960, "100% 960M"),
            (145, 1000, "100% 1.0G"),
        ]
        for pct, freq_mhz, suffix_text in cases:
            with self.subTest(pct=pct, freq_mhz=freq_mhz):
                win = FakeWindow(height=1, width=80)
                start = 5
                width = 30
                SILITOP.draw_core_row(win, 0, start, width, "P0", pct, freq_mhz)
                row = win.render(0)
                segment = row[start:start + width]

                self.assert_drawn_within(row, start, width)
                self.assertIn(suffix_text, segment)

                suffix_start = segment.index(suffix_text)
                self.assertNotIn("█", segment[suffix_start:])
                self.assertNotIn("░", segment[suffix_start:])

    def test_full_width_bar_suffix_stays_intact_at_100_and_over_100(self):
        for pct in (100, 145):
            with self.subTest(pct=pct):
                win = FakeWindow(height=1, width=80)
                start = 7
                width = 18
                SILITOP.draw_hbar_full(win, 0, start, width, pct)
                row = win.render(0)
                segment = row[start:start + width]

                self.assert_drawn_within(row, start, width)
                self.assertIn("100%", segment)

                suffix_start = segment.index("100%")
                self.assertNotIn("█", segment[suffix_start:])
                self.assertNotIn("░", segment[suffix_start:])


    def test_fan_row_suffix_stays_intact(self):
        cases = [
            (50, 2000, "50%", "2000r"),
            (100, 4000, "100%", "4000r"),
            (0, 0, "  0%", "   0r"),
        ]
        for pct, rpm, pct_text, rpm_text in cases:
            with self.subTest(pct=pct, rpm=rpm):
                win = FakeWindow(height=1, width=80)
                start = 5
                width = 30
                SILITOP.draw_fan_row(win, 0, start, width, "F1", pct, rpm)
                row = win.render(0)
                segment = row[start:start + width]

                self.assert_drawn_within(row, start, width)
                self.assertIn(pct_text, segment)
                self.assertIn(rpm_text, segment)

                suffix_start = segment.index(pct_text)
                self.assertNotIn("\u2588", segment[suffix_start:])
                self.assertNotIn("\u2591", segment[suffix_start:])


TOTAL_BYTES_64 = 68_719_476_736  # 64 GiB

VM_STAT_M5_PRO_SNAPSHOT = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                3925.
Pages active:                            757636.
Pages inactive:                          754459.
Pages speculative:                          949.
Pages throttled:                              0.
Pages wired down:                        364720.
Pages purgeable:                              2.
"Translation faults":               11732830959.
Pages copy-on-write:                  502730520.
Pages zero filled:                   7673596724.
Pages reactivated:                   1363654712.
Pages purged:                         229454055.
File-backed pages:                       164217.
Anonymous pages:                        1348827.
Pages stored in compressor:            11460629.
Pages occupied by compressor:           2250658.
"""

SWAP_USAGE_TEXT = "total = 49152.00M  used = 47547.88M  free = 1604.12M  (encrypted)"


def _make_fake_check_output(vm_text, swap_text=SWAP_USAGE_TEXT):
    def fake(args, **kwargs):
        if args and args[0] == "vm_stat":
            return vm_text
        if args[:2] == ["sysctl", "-n"] and len(args) >= 3 and args[2] == "vm.swapusage":
            return swap_text
        raise FileNotFoundError(args)
    return fake


class RamMetricsTests(unittest.TestCase):
    def _run(self, vm_text, swap_text=SWAP_USAGE_TEXT, total_bytes=TOTAL_BYTES_64):
        with mock.patch.object(SILITOP.subprocess, "check_output",
                               side_effect=_make_fake_check_output(vm_text, swap_text)):
            return SILITOP.get_ram_metrics(total_bytes)

    def test_m5_pro_snapshot_matches_activity_monitor(self):
        info = self._run(VM_STAT_M5_PRO_SNAPSHOT)
        self.assertEqual(info["total_gb"], 64.0)
        # Formula B on snapshot: 61.42 GiB
        self.assertGreaterEqual(info["used_gb"], 61.3)
        self.assertLessEqual(info["used_gb"], 61.6)
        self.assertGreaterEqual(info["pct"], 95)
        self.assertLessEqual(info["pct"], 96)
        # Breakdown matches Activity Monitor within rounding
        self.assertGreaterEqual(info["app_gb"], 20.4)
        self.assertLessEqual(info["app_gb"], 20.7)
        self.assertGreaterEqual(info["wired_gb"], 5.5)
        self.assertLessEqual(info["wired_gb"], 5.7)
        self.assertGreaterEqual(info["compressed_gb"], 34.2)
        self.assertLessEqual(info["compressed_gb"], 34.5)
        self.assertGreaterEqual(info["cached_gb"], 2.4)
        self.assertLessEqual(info["cached_gb"], 2.6)
        # Swap parsed from SWAP_USAGE_TEXT (48 GiB total, 46.4 GiB used)
        self.assertGreater(info["swap_total_gb"], 47.5)
        self.assertGreater(info["swap_used_gb"], 46.0)

    def test_low_pressure_idle(self):
        # Synthetic snapshot: 64 GiB total, ~80% available as free + file-cache
        vm_text = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                            2000000.
Pages active:                           300000.
Pages inactive:                         200000.
Pages speculative:                       50000.
Pages wired down:                       200000.
Pages purgeable:                         10000.
File-backed pages:                     1000000.
Anonymous pages:                        500000.
Pages occupied by compressor:           100000.
"""
        info = self._run(vm_text)
        self.assertLess(info["pct"], 30)
        self.assertGreater(info["cached_gb"], 0)

    def test_missing_file_backed_falls_back_to_formula_a(self):
        # Omit File-backed pages; keep Anonymous + compressor
        vm_text = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              10000.
Pages active:                           500000.
Pages inactive:                         500000.
Pages speculative:                        1000.
Pages wired down:                       300000.
Pages purgeable:                             0.
Anonymous pages:                       1000000.
Pages occupied by compressor:          2000000.
"""
        info = self._run(vm_text)
        # Formula A: used = wired (300k) + compressor (2M) + anon (1M) = 3.3M pages
        # 3,300,000 * 16384 / 1024**3 ≈ 50.3 GiB
        self.assertGreaterEqual(info["used_gb"], 50.0)
        self.assertLessEqual(info["used_gb"], 50.6)
        self.assertEqual(info["cached_gb"], 0)
        self.assertGreater(info["app_gb"], 0)

    def test_missing_anonymous_and_file_backed_falls_back_to_legacy(self):
        vm_text = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                             100000.
Pages active:                           500000.
Pages inactive:                         400000.
Pages speculative:                       50000.
Pages wired down:                       300000.
Pages purgeable:                             0.
"""
        info = self._run(vm_text)
        # Legacy: used = total - (free + inactive + spec) = 4194304 - 550000 = 3,644,304 pages
        # 3,644,304 * 16384 / 1024**3 ≈ 55.6 GiB
        self.assertGreaterEqual(info["used_gb"], 55.0)
        self.assertLessEqual(info["used_gb"], 56.1)
        self.assertEqual(info["cached_gb"], 0)
        self.assertEqual(info["app_gb"], 0)

    def test_zero_anonymous_does_not_go_negative(self):
        # Anonymous=0 but purgeable>0 — clamp must keep app_gb at 0
        vm_text = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                            1000000.
Pages active:                          1000000.
Pages inactive:                         500000.
Pages speculative:                       50000.
Pages wired down:                       300000.
Pages purgeable:                           100.
File-backed pages:                      500000.
Anonymous pages:                             0.
Pages occupied by compressor:           500000.
"""
        info = self._run(vm_text)
        self.assertEqual(info["app_gb"], 0)
        self.assertGreaterEqual(info["used_gb"], 0)

    def test_pct_clamped_to_100(self):
        # Pathological: report essentially nothing as free/cached → used > total possible
        vm_text = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                  0.
Pages active:                          2000000.
Pages inactive:                              0.
Pages speculative:                           0.
Pages wired down:                       500000.
Pages purgeable:                             0.
File-backed pages:                           0.
Anonymous pages:                       1500000.
Pages occupied by compressor:          2500000.
"""
        info = self._run(vm_text)
        self.assertLessEqual(info["pct"], 100)
        self.assertLessEqual(info["used_gb"], info["total_gb"])

    def test_swap_parsing_unchanged(self):
        info = self._run(VM_STAT_M5_PRO_SNAPSHOT,
                         swap_text="total = 2048.00M  used = 512.50M  free = 1535.50M  (encrypted)")
        self.assertAlmostEqual(info["swap_total_gb"], 2.0, places=1)
        self.assertAlmostEqual(info["swap_used_gb"], 0.5, places=1)

    def test_subprocess_failure_returns_defaults_not_raise(self):
        def boom(args, **kwargs):
            raise FileNotFoundError(args)
        with mock.patch.object(SILITOP.subprocess, "check_output", side_effect=boom):
            info = SILITOP.get_ram_metrics(TOTAL_BYTES_64)
        # Total still derived from total_bytes; everything else stays at zero defaults
        self.assertEqual(info["total_gb"], 64.0)
        self.assertEqual(info["used_gb"], 0)
        self.assertEqual(info["pct"], 0)
        self.assertEqual(info["app_gb"], 0)
        self.assertEqual(info["wired_gb"], 0)
        self.assertEqual(info["compressed_gb"], 0)
        self.assertEqual(info["cached_gb"], 0)
        self.assertEqual(info["swap_total_gb"], 0)
        self.assertEqual(info["swap_used_gb"], 0)


if __name__ == "__main__":
    unittest.main()
