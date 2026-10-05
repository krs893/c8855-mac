import csv
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from counter import Counter, CounterError, decode_count, setup_packet
import reference_session as server


class FakeUSB:
    def __init__(self, data=b"\x14\x00\x00\x00", fail_start=False):
        self.data, self.fail_start, self.writes = data, fail_start, []
        self.drained, self.closed = 0, False

    def devices(self, open_device=False):
        return [{"vid": "0661", "pid": "1300"}]

    def write(self, data):
        self.writes.append(data)
        if self.fail_start and data[0] == 3:
            raise CounterError("start failed")

    def drain(self):
        self.drained += 1

    def read(self, size, timeout_ms):
        return self.data

    def close(self):
        self.closed = True


class ProtocolTests(unittest.TestCase):
    def test_official_dll_one_gate_block_commands(self):
        # Values independently taken from DLL Setup and CountStart calls.
        self.assertEqual(setup_packet("1s"), bytes.fromhex("01 0f 01 00 04 00 00 00"))
        usb = FakeUSB()
        c = Counter(usb)
        c.start("1s")
        self.assertEqual(c.read_count(), 20)
        c.stop()
        self.assertEqual([w[0] for w in usb.writes], [4, 7, 1, 3, 4])
        self.assertEqual(usb.drained, 2)
        self.assertFalse(any(w[0] in (5, 6) for w in usb.writes))

    def test_little_endian_unsigned_not_signed(self):
        self.assertEqual(decode_count(bytes.fromhex("78 56 34 92")), 0x92345678)

    def test_fifo_error_not_valid_count(self):
        with self.assertRaises(CounterError):
            decode_count(b"\xff" * 4)

    def test_partial_data_not_padded_with_zeros(self):
        with self.assertRaises(CounterError):
            decode_count(b"\x14\x00")

    def test_stop_after_failed_start(self):
        usb = FakeUSB(fail_start=True)
        c = Counter(usb)
        with self.assertRaises(CounterError):
            c.start("1s")
        c.stop()
        self.assertEqual(usb.writes[-1], b"\x04")

    def test_invalid_gate_sends_nothing(self):
        usb = FakeUSB()
        with self.assertRaises(CounterError):
            Counter(usb).start("1us")
        self.assertEqual(usb.writes, [])


class SessionTests(unittest.TestCase):
    def test_csv_persisted_and_usb_closed(self):
        usb = FakeUSB()
        with tempfile.TemporaryDirectory() as folder, patch.object(server, "ROOT", Path(folder)), patch.object(server, "USB", return_value=usb):
            s = server.Session()
            s.start("1s", 2)
            s.thread.join(2)
            self.assertFalse(s.running)
            self.assertEqual(len(s.rows), 2)
            self.assertEqual(s.rows[0]["cps"], 20)
            with Path(s.file).open() as stream:
                disk = list(csv.reader(stream))
            self.assertEqual(len(disk), 3)
            downloaded = list(csv.reader(io.StringIO(s.csv_data().decode("utf-8-sig"))))
            self.assertEqual(disk, downloaded)
            self.assertTrue(usb.closed)
            self.assertEqual(usb.writes[-1], b"\x04")

    def test_transfer_error_saves_no_fake_zero(self):
        usb = FakeUSB(data=b"\xff" * 4)
        with tempfile.TemporaryDirectory() as folder, patch.object(server, "ROOT", Path(folder)), patch.object(server, "USB", return_value=usb):
            s = server.Session()
            s.start("1s", 1)
            s.thread.join(2)
            self.assertTrue(s.error)
            self.assertEqual(s.rows, [])
            self.assertTrue(usb.closed)

    def test_probe_does_not_write(self):
        usb = FakeUSB()
        with patch.object(server, "USB", return_value=usb):
            server.Session().probe()
        self.assertEqual(usb.writes, [])
        self.assertTrue(usb.closed)

    def test_bad_duration_does_not_start_worker(self):
        for duration in [float("nan"), float("inf"), 0, 3601]:
            s = server.Session()
            with self.assertRaises(CounterError):
                s.start("1s", duration)
            self.assertIsNone(s.thread)


if __name__ == "__main__":
    unittest.main()
