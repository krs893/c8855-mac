"""End-to-end HTTP/client/CSV tests with the actual app model and mock USB.

Never opens a physical USB device. The isolated test server writes to a temp folder.
"""
import csv
import json
import pathlib
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
        sources = ["CounterModel.swift", "PlotData.swift", "LocalAPI.swift", "APIConfig.swift", "APIHarness.swift"]
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(cls.folder / "cache"),
                        "-import-objc-header", str(root / "USBBridge.h"), *[str(root / name) for name in sources],
                        str(cls.folder / "bridge.o"), "-o", str(cls.folder / "server"),
                        "-framework", "Cocoa", "-framework", "SwiftUI", "-framework", "Network"], check=True)
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

    def test_stop_and_reject_busy_start(self):
        self.client.start(0.1)
        with self.assertRaises(CounterAPIError):
            self.client.start(0.1)
        self.assertFalse(self.client.stop()["running"])

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

    def test_bad_settings_are_rejected_without_starting(self):
        for payload in [{"gate_seconds": True}, {"gate_seconds": 0.01}, {"duration_seconds": 0},
                        {"duration_seconds": True}, {"extra": 1}]:
            with self.assertRaises(CounterAPIError):
                self.client._request("/start", payload)
        self.assertFalse(self.client.status()["running"])

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
