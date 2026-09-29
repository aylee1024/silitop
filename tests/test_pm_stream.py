"""Behavior of the bounded powermetrics plist stream reader."""

import datetime
import importlib.util
import os
import pathlib
import plistlib
import sys
import unittest
from importlib.machinery import SourceFileLoader
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parent.parent
_loader = SourceFileLoader("SILITOP_STREAM", str(ROOT / "silitop"))
_spec = importlib.util.spec_from_loader("SILITOP_STREAM", _loader)
SILITOP = importlib.util.module_from_spec(_spec)
sys.modules["SILITOP_STREAM"] = SILITOP
_loader.exec_module(SILITOP)


def sample(value):
    return plistlib.dumps({
        "timestamp": datetime.datetime(2026, 9, 28, 12, 0, value),
        "value": value,
    })


class PowermetricsReaderTests(unittest.TestCase):
    def setUp(self):
        self.read_fd, self.write_fd = os.pipe()
        self.stream = os.fdopen(self.read_fd, "rb", buffering=0)

    def tearDown(self):
        self.stream.close()
        os.close(self.write_fd)

    def test_complete_sample_is_available_before_next_delimiter(self):
        reader = SILITOP.PowermetricsReader(self.stream)
        os.write(self.write_fd, sample(1))
        self.assertEqual(reader.read_available()["value"], 1)

    def test_split_sample_waits_for_completion(self):
        reader = SILITOP.PowermetricsReader(self.stream)
        data = sample(2)
        os.write(self.write_fd, data[:len(data) // 2])
        self.assertIsNone(reader.read_available())
        os.write(self.write_fd, data[len(data) // 2:])
        self.assertEqual(reader.read_available()["value"], 2)

    def test_multiple_samples_return_the_latest(self):
        reader = SILITOP.PowermetricsReader(self.stream)
        os.write(self.write_fd, sample(3) + b"\0" + sample(4) + b"\0")
        self.assertEqual(reader.read_available()["value"], 4)
        self.assertIsNone(reader.read_available())

    def test_malformed_complete_sample_is_reported(self):
        reader = SILITOP.PowermetricsReader(self.stream)
        os.write(self.write_fd, b"not a plist\0")
        with self.assertRaisesRegex(RuntimeError, "invalid powermetrics plist"):
            reader.read_available()

    def test_oversized_partial_sample_is_reported(self):
        with mock.patch.object(SILITOP, "MAX_PM_FRAME_BYTES", 16):
            reader = SILITOP.PowermetricsReader(self.stream)
            os.write(self.write_fd, b"x" * 17)
            with self.assertRaisesRegex(RuntimeError, "exceeds"):
                reader.read_available()


if __name__ == "__main__":
    unittest.main()
