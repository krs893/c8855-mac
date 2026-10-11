"""End-to-end HTTP/client/CSV tests with the actual app model and mock USB.

Never opens a physical USB device. The isolated test server writes to a temp folder.
"""
import csv
import json
import os
import pathlib
import signal
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from counter_client import CounterClient, CounterAPIError


class APITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="c8855-api-tests-")
        cls.folder = pathlib.Path(cls.temp.name)
        root = pathlib.Path(__file__).resolve().parent
        # Slow mock transfers to expose real streaming/stop behavior without hardware.
        mock = (root / "mock_usb.c").read_text().replace("#include <stdint.h>", "#include <stdint.h>\n#include <unistd.h>")
        mock = mock.replace("unsigned char bytes[4]", "usleep(100000); unsigned char bytes[4]")
        (cls.folder / "mock.c").write_text(mock)
        subprocess.run(["xcrun", "clang", "-dynamiclib", str(cls.folder / "mock.c"), "-o", str(cls.folder / "mock.dylib")], check=True)
        subprocess.run(["xcrun", "clang", "-c", str(root / "USBBridge.c"), "-o", str(cls.folder / "bridge.o")], check=True)
        sources = ["CounterModel.swift", "MeasurementExport.swift", "PlotData.swift", "LocalAPI.swift", "APIConfig.swift", "APIHarness.swift"]
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(cls.folder / "cache"),
                        "-import-objc-header", str(root / "USBBridge.h"), *[str(root / name) for name in sources],
                        str(cls.folder / "bridge.o"), "-o", str(cls.folder / "server"),
                        "-framework", "Cocoa", "-framework", "SwiftUI", "-framework", "Network"], check=True)
        cls.cpp = cls.folder / "c8855_realtime"
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-O1", "-Wall", "-Wextra", "-Wpedantic", "-Werror",
                        "-I" + str(root / "cpp/include"), "-I" + str(root / "cpp/vendor"),
                        str(root / "cpp/c8855_client.cpp"), str(root / "cpp/example_realtime.cpp"),
                        "-lcurl", "-pthread", "-o", str(cls.cpp)], check=True)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            cls.port = probe.getsockname()[1]
        cls.process = subprocess.Popen([str(cls.folder / "server"), str(cls.folder / "mock.dylib"), str(cls.folder / "records"), str(cls.port)])
        cls.client = CounterClient(cls.port, timeout=10)
        deadline = time.monotonic() + 10
        while True:
            try:
                state = cls.client.status()
                if state["connected"] and not state["checking"]:
                    break
            except CounterAPIError:
                pass
            if time.monotonic() > deadline:
                cls.process.terminate(); cls.process.wait()
                raise RuntimeError("Local API test server did not start")
            time.sleep(0.05)

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate(); cls.process.wait(timeout=5)
        cls.temp.cleanup()

    def tearDown(self):
        self.client.stop()

    def test_live_samples_recording_and_session_identity(self):
        with self.client.stream() as events:
            state = self.client.start(0.1, 1)
            session = state["session_id"]
            received = []
            for event in events:
                if event.get("session_id") != session:
                    continue
                if event["type"] == "sample":
                    received.append(event)
                if event["type"] == "status" and not event["running"]:
                    self.assertEqual(event["error"], "")
                    break
        self.assertEqual([row["sample"] for row in received], list(range(1, 11)))
        self.assertTrue(all(row["counts"] == 0x92345678 for row in received))
        self.assertTrue(all(row["counts_per_second"] == 0x92345678 / 0.1 for row in received))
        self.assertGreater(received[-1]["received_unix_seconds"], received[0]["received_unix_seconds"])
        self.assertGreater(received[-1]["received_monotonic_seconds"], received[0]["received_monotonic_seconds"])
        with open(self.client.status()["csv_file"], newline="") as file:
            rows = list(csv.DictReader(file))
        self.assertEqual(len(rows), 10)
        self.assertEqual(int(rows[-1]["counts"]), received[-1]["counts"])
        self.assertEqual(rows[-1]["session_id"], session)
        self.assertEqual(float(rows[-1]["received_unix_seconds"]), received[-1]["received_unix_seconds"])
        state = self.client.status()
        metadata_path = pathlib.Path(state["metadata_file"])
        metadata = json.loads(metadata_path.read_text())
        self.assertEqual(metadata_path.parent, pathlib.Path(state["csv_file"]).parent)
        self.assertEqual(metadata["session_id"], session)
        self.assertEqual(metadata["csv_file"], pathlib.Path(state["csv_file"]).name)
        self.assertEqual(metadata["gate_seconds"], 0.1)
        self.assertEqual(metadata["duration_seconds"], 1)
        self.assertEqual(metadata["software_version"], "development")
        self.assertEqual(metadata["saved_samples"], len(rows))
        self.assertEqual(metadata["state"], "finished")
        self.assertFalse(metadata["count_corrections_applied"])

    def test_stop_and_reject_busy_start(self):
        self.client.start(0.1)
        with self.assertRaises(CounterAPIError):
            self.client.start(0.1)
        self.assertFalse(self.client.stop()["running"])

    def test_stale_session_stop_cannot_stop_new_measurement(self):
        old_session = self.client.start(0.1)["session_id"]
        self.client.stop(session_id=old_session)
        session = self.client.start(0.1)["session_id"]
        with self.assertRaisesRegex(CounterAPIError, "session changed"):
            self.client.stop(session_id=old_session)
        self.assertEqual(self.client.status()["session_id"], session)
        self.assertTrue(self.client.status()["running"])

    def test_bad_stop_session_rejected_without_stopping(self):
        self.client.start(0.1)
        for payload in [{"session_id": ""}, {"session_id": True}, {"session_id": None}, {"extra": 1}]:
            with self.assertRaises(CounterAPIError):
                self.client._request("/stop", payload)
        self.assertTrue(self.client.status()["running"])

    def test_usb_failure_keeps_prior_blocks_and_failure_metadata(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        process = subprocess.Popen([str(self.folder / "server"), str(self.folder / "mock.dylib"),
                                    str(self.folder / "error-records"), str(port)],
                                   env=dict(os.environ, C8855_TEST_USB_MODE="8"))
        client = CounterClient(port, timeout=5)
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    if client.status()["connected"]:
                        break
                except CounterAPIError:
                    pass
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            with client.stream() as events:
                session = client.start(0.01, 1)["session_id"]
                received = []
                for event in events:
                    if event.get("session_id") != session:
                        continue
                    if event["type"] == "sample":
                        received.append(event)
                    elif event["type"] == "status" and not event["running"]:
                        self.assertTrue(event["error"])
                        break
            state = client.status()
            with open(state["csv_file"], newline="") as file:
                rows = list(csv.DictReader(file))
            self.assertEqual([int(row["counts"]) for row in rows], list(range(1, 21)))
            self.assertEqual([row["counts"] for row in received], list(range(1, 21)))
            metadata = json.loads(pathlib.Path(state["metadata_file"]).read_text())
            self.assertEqual(metadata["state"], "failed")
            self.assertEqual(metadata["saved_samples"], 20)
            self.assertTrue(metadata["error"])
        finally:
            process.terminate()
            process.wait(timeout=5)

    def test_cpp_numeric_suffixes_rejected_without_start(self):
        for option, value in [("--gate", "0.1junk"), ("--seconds", "1junk"), ("--port", "8855junk")]:
            run = subprocess.run([str(self.cpp), "--port", str(self.port), option, value],
                                 capture_output=True, text=True, timeout=3)
            self.assertEqual(run.returncode, 1)
            self.assertIn("Invalid numeric argument", run.stderr)
        self.assertFalse(self.client.status()["running"])

    def test_subscriber_disconnect_does_not_stop_recording(self):
        self.client.start(0.1)
        with self.client.stream() as events:
            for event in events:
                if event["type"] == "sample":
                    previous = event["sample"]
                    break
        time.sleep(0.25)
        state = self.client.status()
        self.assertTrue(state["running"])
        self.assertGreater(state["sample_count"], previous)
        self.client.stop()

    def test_cpp_live_stream_matches_csv(self):
        run = subprocess.run([str(self.cpp), "--port", str(self.port), "--gate", "0.1", "--seconds", "1", "--json"],
                             capture_output=True, text=True, timeout=20)
        self.assertEqual(run.returncode, 0, run.stderr)
        samples = [json.loads(line) for line in run.stdout.splitlines()]
        self.assertEqual([row["sample"] for row in samples], list(range(1, 11)))
        self.assertTrue(all(row["counts"] == 0x92345678 for row in samples))
        self.assertTrue(all(row["counts_per_second"] == 0x92345678 / 0.1 for row in samples))
        state = self.client.status()
        self.assertFalse(state["running"])
        with open(state["csv_file"], newline="") as file:
            rows = list(csv.DictReader(file))
        self.assertEqual(len(rows), 10)
        self.assertEqual(rows[-1]["session_id"], samples[-1]["session_id"])
        self.assertEqual(float(rows[-1]["received_unix_seconds"]), samples[-1]["received_unix_seconds"])

    def test_cpp_ctrl_c_stops_continuous_measurement(self):
        process = subprocess.Popen([str(self.cpp), "--port", str(self.port), "--continuous", "--json"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            first = json.loads(process.stdout.readline())
            self.assertEqual(first["sample"], 1)
            process.send_signal(signal.SIGINT)
            remaining, error = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, error)
            state = self.client.status()
            self.assertFalse(state["running"])
            samples = [first] + [json.loads(line) for line in remaining.splitlines()]
            with open(state["csv_file"], newline="") as file:
                rows = list(csv.DictReader(file))
            self.assertEqual(len(samples), len(rows))
            self.assertEqual(samples[-1]["sample"], int(rows[-1]["sample"]))
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
            process.stdout.close(); process.stderr.close()

    def test_cpp_busy_failure_does_not_stop_other_measurement(self):
        self.client.start(0.1)
        run = subprocess.run([str(self.cpp), "--port", str(self.port), "--seconds", "1"],
                             capture_output=True, text=True, timeout=15)
        self.assertEqual(run.returncode, 1)
        self.assertIn("Counter is busy", run.stderr)
        self.assertTrue(self.client.status()["running"])
        self.client.stop()

    def test_cpp_fast_samples_match_csv(self):
        run = subprocess.run([str(self.cpp), "--port", str(self.port), "--gate", "0.01", "--seconds", "1", "--json"],
                             capture_output=True, text=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        samples = [json.loads(line) for line in run.stdout.splitlines() if line.startswith('{')]
        self.assertEqual([row["sample"] for row in samples], list(range(1, 101)))
        self.assertTrue(all(row["gate_seconds"] == 0.01 for row in samples))
        self.assertTrue(all(row["counts_per_second"] == 0x92345678 / 0.01 for row in samples))
        with open(self.client.status()["csv_file"], newline="") as file:
            rows = list(csv.DictReader(file))
        self.assertEqual([int(row["sample"]) for row in rows], list(range(1, 101)))
        self.assertEqual([int(row["counts"]) for row in rows], [row["counts"] for row in samples])

    def test_bad_settings_are_rejected_without_starting(self):
        for payload in [{"gate_seconds": True}, {"gate_seconds": 0.001}, {"duration_seconds": 0},
                        {"duration_seconds": True}, {"extra": 1}]:
            with self.assertRaises(CounterAPIError):
                self.client._request("/start", payload)
        self.assertFalse(self.client.status()["running"])

    def test_duration_ending_inside_usb_block_retains_received_samples(self):
        with self.client.stream() as events:
            session = self.client.start(0.01, 1.01)["session_id"]
            received = []
            for event in events:
                if event.get("session_id") != session:
                    continue
                if event["type"] == "sample":
                    received.append(event)
                elif event["type"] == "status" and not event["running"]:
                    self.assertEqual(event["error"], "")
                    break
        # 101 requested gates require eleven complete 10-sample USB transfers.
        self.assertEqual([row["sample"] for row in received], list(range(1, 111)))
        with open(self.client.status()["csv_file"], newline="") as file:
            rows = list(csv.DictReader(file))
        self.assertEqual([int(row["sample"]) for row in rows], list(range(1, 111)))

    def test_manual_stop_retains_inflight_usb_block(self):
        self.client.start(0.01)
        deadline = time.monotonic() + 3
        while self.client.status()["status"] != "測定中":
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.005)
        # The mock transfer takes 100 ms; stop while the first block is in flight.
        time.sleep(0.01)
        state = self.client.stop()
        with open(state["csv_file"], newline="") as file:
            rows = list(csv.DictReader(file))
        self.assertEqual(state["sample_count"], 10)
        self.assertEqual([int(row["sample"]) for row in rows], list(range(1, 11)))
        metadata = json.loads(pathlib.Path(state["metadata_file"]).read_text())
        self.assertIsNone(metadata["duration_seconds"])
        self.assertTrue(metadata["continuous"])
        self.assertEqual(metadata["usb_block_samples"], 10)
        self.assertEqual(metadata["saved_samples"], 10)
        self.assertTrue(metadata["stop_requested"])

    def test_browser_origin_and_foreign_host_are_rejected(self):
        for headers in [{"Origin": "https://example.com"}, {"Host": "example.com"}]:
            request = urllib.request.Request(self.client.base + "/status", headers=headers)
            with self.assertRaises(urllib.error.HTTPError) as caught:
                self.client.opener.open(request)
            self.assertEqual(caught.exception.code, 403)
            caught.exception.close()

    def test_fragmented_post_request(self):
        payload = b'{}'
        request = (f"POST /api/stop HTTP/1.1\r\nHost: 127.0.0.1:{self.port}\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n").encode()
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as connection:
            connection.sendall(request[:12]); connection.sendall(request[12:])
            connection.sendall(payload[:1]); time.sleep(0.02); connection.sendall(payload[1:])
            response = b""
            while True:
                part = connection.recv(4096)
                if not part:
                    break
                response += part
        self.assertIn(b"202 Response", response)
        self.assertFalse(json.loads(response.split(b"\r\n\r\n", 1)[1])["running"])
