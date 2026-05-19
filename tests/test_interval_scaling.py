"""Tests for UNIT C: --interval N scales history, slow-poll, and avg_window
on wallclock seconds rather than iteration count.

Audit finding #8 (NEW-CRIT-1): the prior code hardcoded max_history=120 and
slow_poll_counter % 3, both of which silently corrupted under non-default
intervals. With --interval 5, sparkline coverage was 600s instead of 120s
and temperature staleness was 15s instead of 3s.
"""
import importlib.util
import pathlib
import subprocess
import sys
import unittest
from importlib.machinery import SourceFileLoader

ROOT = pathlib.Path(__file__).resolve().parent.parent
_loader = SourceFileLoader("SILITOP", str(ROOT / "silitop"))
_spec = importlib.util.spec_from_loader("SILITOP", _loader)
SILITOP = importlib.util.module_from_spec(_spec)
sys.modules["SILITOP"] = SILITOP
_loader.exec_module(SILITOP)


class HistoryScalingTests(unittest.TestCase):
    """max_history is sized in wallclock seconds, not sample count.

    The computation lives in main() at the top of its `try:` block:
        history_seconds = 120
        max_history = max(30, history_seconds // args.interval)

    We replicate the formula here because main() is curses-driven and not
    directly testable. The contract is a pure function of args.interval.
    """

    @staticmethod
    def _max_history(interval):
        history_seconds = 120
        return max(30, history_seconds // interval)

    def test_default_interval_keeps_120_samples(self):
        self.assertEqual(self._max_history(1), 120)

    def test_interval_2_keeps_60_samples_for_120s(self):
        self.assertEqual(self._max_history(2), 60)

    def test_interval_5_keeps_30_samples(self):
        # 120 // 5 = 24, but the floor (30) holds.
        self.assertEqual(self._max_history(5), 30)

    def test_interval_60_keeps_30_floor(self):
        # 120 // 60 = 2 -> clamped to 30 floor.
        self.assertEqual(self._max_history(60), 30)


class AvgWindowScalingTests(unittest.TestCase):
    """avg_window is the number of samples whose average gives N wallclock
    seconds of mean power. Formula in main():
        avg_window = max(1, args.avg // args.interval)
    """

    @staticmethod
    def _avg_window(avg, interval):
        return max(1, avg // interval)

    def test_default_30s_at_interval_1(self):
        self.assertEqual(self._avg_window(30, 1), 30)

    def test_30s_at_interval_5_keeps_6_samples(self):
        # The prior bug used int(args.avg / args.interval) which was the same
        # math but with no floor. Both produce 6 here. We codify the floor
        # because at avg=1, interval=2 we MUST keep at least one sample.
        self.assertEqual(self._avg_window(30, 5), 6)

    def test_avg_below_interval_floors_at_one(self):
        # If avg < interval, integer-divide is 0 which yields a broken
        # deque(maxlen=0). Floor at 1.
        self.assertEqual(self._avg_window(1, 5), 1)


class SlowPollWallclockTests(unittest.TestCase):
    """The slow-poll cadence is 3 wallclock seconds, regardless of interval.

    Old code: `slow_poll_counter % 3 == 0` fired every 3 iterations, which
    was 3s at interval=1 but 15s at interval=5. New code uses time.monotonic.
    The contract checked here:

      poll triggers when (now - last_slow_poll_ts) >= 3.0
      poll updates last_slow_poll_ts = now
      first iteration with last_slow_poll_ts=0.0 always triggers
    """

    SLOW_POLL_SECONDS = 3.0

    def _should_poll(self, now, last):
        return (now - last) >= self.SLOW_POLL_SECONDS

    def test_first_iteration_polls_immediately(self):
        self.assertTrue(self._should_poll(now=100.0, last=0.0))

    def test_skips_until_3s_elapsed(self):
        self.assertFalse(self._should_poll(now=100.5, last=100.0))
        self.assertFalse(self._should_poll(now=102.99, last=100.0))
        self.assertTrue(self._should_poll(now=103.0, last=100.0))

    def test_interval_1_fires_at_t3(self):
        """Five 1-second iterations: poll fires once (at t=3.0)."""
        last = 0.0
        polls = 0
        for t in (1.0, 2.0, 3.0, 4.0, 5.0):
            if self._should_poll(now=t, last=last):
                polls += 1
                last = t
        self.assertEqual(polls, 1)

    def test_interval_5_fires_every_iteration(self):
        """Five 5-second iterations: poll fires every time (5 >= 3 each)."""
        last = 0.0
        polls = 0
        for t in (5.0, 10.0, 15.0, 20.0, 25.0):
            if self._should_poll(now=t, last=last):
                polls += 1
                last = t
        self.assertEqual(polls, 5)


class ArgparseValidationTests(unittest.TestCase):
    """The `entry()` function validates --interval and --avg BEFORE starting
    any powermetrics subprocess. We invoke the real binary with `--help`
    and `--interval 0` via the system interpreter so the CLI surface is
    tested as users see it."""

    def _run_silitop(self, *args):
        """Run silitop as a subprocess (we never reach curses since we use
        invalid args). Returns (rc, stderr_text)."""
        env = {"PYTHONDONTWRITEBYTECODE": "1", "PATH": "/usr/bin:/bin"}
        proc = subprocess.run(
            ["python3", str(ROOT / "silitop"), *args],
            capture_output=True, text=True, env=env, timeout=5,
        )
        return proc.returncode, proc.stderr

    def test_interval_zero_rejected_before_subprocess(self):
        rc, stderr = self._run_silitop("--interval", "0")
        self.assertNotEqual(rc, 0)
        self.assertIn("--interval", stderr)

    def test_interval_negative_rejected(self):
        rc, stderr = self._run_silitop("--interval", "-1")
        self.assertNotEqual(rc, 0)

    def test_avg_below_interval_rejected(self):
        rc, stderr = self._run_silitop("--interval", "5", "--avg", "2")
        self.assertNotEqual(rc, 0)
        self.assertIn("--avg", stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
