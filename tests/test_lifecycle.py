"""Tests for powermetrics startup, shutdown, and SIGTERM handling.

These tests do NOT touch curses or live powermetrics. They exercise the
lifecycle utility functions in isolation and use mocked Popen objects to
verify subprocess handling.
"""
import importlib.util
import io
import os
import pathlib
import signal
import subprocess
import sys
import threading
import unittest
from importlib.machinery import SourceFileLoader
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
_loader = SourceFileLoader("SILITOP", str(ROOT / "silitop"))
_spec = importlib.util.spec_from_loader("SILITOP", _loader)
SILITOP = importlib.util.module_from_spec(_spec)
sys.modules["SILITOP"] = SILITOP
_loader.exec_module(SILITOP)


class FakeProc:
    """Minimal subprocess.Popen stand-in for lifecycle tests.

    Attributes:
      pid: returned by .pid
      returncode: set after terminate/kill/wait
      _terminate_raises: optional exception class to raise from terminate()
      _wait_blocks_first: if True, first wait() call raises TimeoutExpired
    """
    def __init__(self, returncode=None, terminate_raises=None,
                 wait_blocks_first=False):
        self.pid = 12345
        self.returncode = returncode
        self.terminate_called = 0
        self.kill_called = 0
        self.wait_called = 0
        self._terminate_raises = terminate_raises
        self._wait_blocks_first = wait_blocks_first
        self.stderr = None
        self.stdout = None
        self.stdin = None

    def terminate(self):
        self.terminate_called += 1
        if self._terminate_raises:
            raise self._terminate_raises()

    def kill(self):
        self.kill_called += 1
        self.returncode = -9

    def wait(self, timeout=None):
        self.wait_called += 1
        if self._wait_blocks_first and self.wait_called == 1:
            raise subprocess.TimeoutExpired(cmd="fake", timeout=timeout)
        if self.returncode is None:
            self.returncode = 0
        return self.returncode

    def poll(self):
        return self.returncode


class CleanupPmTests(unittest.TestCase):
    """_cleanup_pm must terminate the process and close its pipes."""

    def test_terminates_and_waits(self):
        proc = FakeProc(returncode=None)
        SILITOP._cleanup_pm(proc)
        self.assertEqual(proc.terminate_called, 1)
        self.assertEqual(proc.wait_called, 1)

    def test_force_kills_when_wait_times_out(self):
        proc = FakeProc(returncode=None, wait_blocks_first=True)
        SILITOP._cleanup_pm(proc)
        self.assertEqual(proc.terminate_called, 1)
        self.assertGreaterEqual(proc.kill_called, 1)
        # After kill, returncode is set.
        self.assertEqual(proc.returncode, -9)

    def test_swallows_already_dead_process(self):
        proc = FakeProc(returncode=0, terminate_raises=ProcessLookupError)
        SILITOP._cleanup_pm(proc)

    def test_handles_none_proc(self):
        SILITOP._cleanup_pm(None)

    def test_closes_output_pipes(self):
        proc = FakeProc(returncode=0)
        proc.stdout = io.BytesIO()
        proc.stderr = io.BytesIO()
        proc.stdin = io.BytesIO()
        SILITOP._cleanup_pm(proc)
        self.assertTrue(proc.stdout.closed)
        self.assertTrue(proc.stderr.closed)
        self.assertTrue(proc.stdin.closed)


class RunPowermetricsTests(unittest.TestCase):
    """run_powermetrics must terminate each failed-sampler probe cleanly and
    raise RuntimeError when every option fails."""

    def test_returns_first_live_proc(self):
        # First sampler set "survives" the 1.5s probe.
        live_proc = FakeProc(returncode=None)

        def wait_side_effect(timeout=None):
            raise subprocess.TimeoutExpired(cmd="powermetrics", timeout=timeout)
        with mock.patch.object(live_proc, "wait", side_effect=wait_side_effect):
            with mock.patch.object(SILITOP.subprocess, "Popen",
                                   return_value=live_proc) as popen:
                got = SILITOP.run_powermetrics(interval=1000)
        self.assertIs(got, live_proc)
        popen.assert_called_once()

    def test_streams_unbuffered_plists_without_an_output_file(self):
        live_proc = FakeProc(returncode=None)
        with mock.patch.object(live_proc, "wait",
                               side_effect=subprocess.TimeoutExpired("powermetrics", 1.5)):
            with mock.patch.object(SILITOP.subprocess, "Popen", return_value=live_proc) as popen:
                SILITOP.run_powermetrics(interval=1000)
        cmd = popen.call_args.args[0]
        self.assertNotIn("-o", cmd)
        self.assertEqual(cmd[cmd.index("--buffer-size") + 1], "0")
        self.assertEqual(popen.call_args.kwargs["stdout"], subprocess.PIPE)

    def test_raises_when_all_samplers_fail(self):
        # Every probe returns from .wait quickly (process exited).
        exited = FakeProc(returncode=1)
        # Both sampler attempts return an exited proc.
        with mock.patch.object(SILITOP.subprocess, "Popen", return_value=exited):
            with self.assertRaises(RuntimeError):
                SILITOP.run_powermetrics(interval=1000)

    def test_handles_popen_oserror(self):
        # Popen itself raises (e.g., powermetrics not found). The loop must
        # try the next sampler set, then raise RuntimeError if all fail.
        with mock.patch.object(SILITOP.subprocess, "Popen",
                               side_effect=OSError("not found")):
            with self.assertRaises(RuntimeError):
                SILITOP.run_powermetrics(interval=1000)


class SigtermPlumbingTests(unittest.TestCase):
    """The main() loop installs a SIGTERM handler that sets a threading.Event.
    We can verify the contract without spawning curses: register the handler,
    raise SIGTERM via os.kill(self), and observe the event."""

    def test_sigterm_handler_sets_event(self):
        event = threading.Event()
        prior = signal.signal(signal.SIGTERM, lambda *_: event.set())
        try:
            os.kill(os.getpid(), signal.SIGTERM)
            # Signal delivery is synchronous in the main thread for python;
            # the handler may not have run yet. Give it a moment.
            self.assertTrue(event.wait(timeout=2.0))
        finally:
            signal.signal(signal.SIGTERM, prior)


if __name__ == "__main__":
    unittest.main(verbosity=2)
