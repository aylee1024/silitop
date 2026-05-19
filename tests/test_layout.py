import importlib.util
import os
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


    def test_clamp_pct_safe_against_degenerate_inputs(self):
        """clamp_pct must not crash the curses draw path on None / NaN / inf
        / non-numeric inputs. The prior implementation called int(pct)
        unconditionally and propagated TypeError / ValueError."""
        cases = [
            (None, 0),
            ("not a number", 0),
            (float("nan"), 0),
            (float("inf"), 0),
            (float("-inf"), 0),
            (-50, 0),
            (0, 0),
            (50, 50),
            (99.9, 99),
            (100, 100),
            (145, 100),
        ]
        for inp, expected in cases:
            with self.subTest(inp=inp):
                self.assertEqual(SILITOP.clamp_pct(inp), expected)

    def test_temp_color_thresholds_match_readme(self):
        """README spec: cyan < 50, yellow 50-70 inclusive, red > 70. The
        prior code returned red at exactly 70."""
        # Pair numbers from init_colors: 3 yellow, 4 red, 5 cyan.
        cases = [
            (-10, 3),       # negative -> warning (was: pair 2 plain white)
            (None, 3),      # missing -> warning
            (float("nan"), 3),
            (0, 5),         # zero is a valid measurement (M1 cold-boot edge)
            (25, 5),
            (49.9, 5),
            (50, 3),        # boundary: 50 is yellow
            (60, 3),
            (70, 3),        # boundary: 70 still yellow per README
            (70.5, 4),
            (95, 4),
        ]
        for temp, expected in cases:
            with self.subTest(temp=temp):
                self.assertEqual(SILITOP.temp_color(temp), expected,
                                 f"temp={temp} expected pair {expected}")

    def test_block_chars_and_hbar_removed(self):
        """Audit #50: dead BLOCK_CHARS constant and dead hbar function with
        an off-by-one on negative percentages. Both deleted in UNIT H."""
        self.assertFalse(hasattr(SILITOP, "BLOCK_CHARS"))
        self.assertFalse(hasattr(SILITOP, "hbar"))

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
    """Stub subprocess.check_output. After UNIT F, silitop calls VM_STAT and
    SYSCTL by absolute path; match on basename so tests stay portable across
    PATH-poisoning hardening."""
    def fake(args, **kwargs):
        if args and os.path.basename(args[0]) == "vm_stat":
            return vm_text
        if (args
                and os.path.basename(args[0]) == "sysctl"
                and len(args) >= 3
                and args[1] == "-n"
                and args[2] == "vm.swapusage"):
            return swap_text
        raise FileNotFoundError(args)
    return fake


class RamMetricsTests(unittest.TestCase):
    def _run(self, vm_text, swap_text=SWAP_USAGE_TEXT, total_bytes=TOTAL_BYTES_64):
        with mock.patch.object(SILITOP.subprocess, "check_output",
                               side_effect=_make_fake_check_output(vm_text, swap_text)):
            return SILITOP.get_ram_metrics(total_bytes)

    def test_m5_pro_snapshot_matches_activity_monitor(self):
        # Activity Monitor 14+: used = anonymous + wired + compressor.
        # On this snapshot: 1348827 + 364720 + 2250658 = 3,964,205 pages
        #   * 16384 / 1024**3 = 60.45 GiB
        info = self._run(VM_STAT_M5_PRO_SNAPSHOT)
        self.assertEqual(info["total_gb"], 64.0)
        self.assertGreaterEqual(info["used_gb"], 60.3)
        self.assertLessEqual(info["used_gb"], 60.6)
        self.assertGreaterEqual(info["pct"], 94)
        self.assertLessEqual(info["pct"], 95)
        # Breakdown:
        #   app_gb (Anonymous):    1348827 * 16384 / 1024**3 = 20.57 GiB
        #   wired_gb:               364720 * 16384 / 1024**3 = 5.56 GiB
        #   compressed_gb:         2250658 * 16384 / 1024**3 = 34.32 GiB
        #   cached_gb (File-backed): 164217 * 16384 / 1024**3 = 2.51 GiB
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
        # Used = anonymous(500k) + wired(200k) + compressor(100k) = 800k pages
        #   * 16384 / 1024**3 = 12.21 GiB. On 64 GiB host, ~19.1%.
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
        self.assertGreaterEqual(info["used_gb"], 12.1)
        self.assertLessEqual(info["used_gb"], 12.3)

    def test_returns_none_when_required_counter_missing(self):
        # Missing "Pages occupied by compressor": Activity Monitor 14+ cannot
        # be computed without it. Surface None rather than presenting a
        # guess that won't match the menu bar.
        vm_text = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                             100000.
Pages active:                           500000.
Pages inactive:                         400000.
Pages speculative:                       50000.
Pages wired down:                       300000.
Pages purgeable:                             0.
Anonymous pages:                        500000.
"""
        info = self._run(vm_text)
        self.assertIsNone(info)

    def test_returns_none_when_anonymous_missing(self):
        # Anonymous is now required: without it we can't compute App Memory.
        vm_text = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                             100000.
Pages active:                           500000.
Pages wired down:                       300000.
Pages occupied by compressor:           100000.
"""
        info = self._run(vm_text)
        self.assertIsNone(info)

    def test_pct_clamped_to_100(self):
        # Pathological: anonymous+wired+compressor exceeds total.
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

    def test_subprocess_failure_returns_none(self):
        """Audit finding #2 (CRIT): vm_stat failure must NOT silently degrade to
        Memory: 0/64 GB (0%). It must return None so the caller renders an
        "unavailable" panel. The prior implementation returned a zero-filled
        dict; that contract is now reversed."""
        def boom(args, **kwargs):
            raise FileNotFoundError(args)
        with mock.patch.object(SILITOP.subprocess, "check_output", side_effect=boom):
            info = SILITOP.get_ram_metrics(TOTAL_BYTES_64)
        self.assertIsNone(info)

    def test_swap_subprocess_failure_does_not_void_panel(self):
        """vm_stat works but sysctl vm.swapusage fails; the RAM panel must
        still render with swap reported as 0 (informational), not None."""
        def partial(args, **kwargs):
            if args and os.path.basename(args[0]) == "vm_stat":
                return VM_STAT_M5_PRO_SNAPSHOT
            raise FileNotFoundError(args)
        with mock.patch.object(SILITOP.subprocess, "check_output", side_effect=partial):
            info = SILITOP.get_ram_metrics(TOTAL_BYTES_64)
        self.assertIsNotNone(info)
        self.assertEqual(info["swap_total_gb"], 0)
        self.assertEqual(info["swap_used_gb"], 0)


if __name__ == "__main__":
    unittest.main()
