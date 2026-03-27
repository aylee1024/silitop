import importlib.util
from importlib.machinery import SourceFileLoader
from pathlib import Path
import unittest


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


if __name__ == "__main__":
    unittest.main()
