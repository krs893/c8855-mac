"""C++ CLI against isolated HTTP fakes; never opens USB or the normal app API."""
import csv
import json
import pathlib
import queue
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeAPI:
    def __init__(self, mode="normal"):
        self.mode = mode
        self.lock = threading.Lock()
        self.subscribers = []
        self.running = False
        self.session = "preceding"
        self.sample_count = 0
        self.starts = 0
        self.gate = 0.1
        self.stop_event = threading.Event()
        self.posts = []
        self.worker = None
        fake = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass

            def reply(self, code, value):
                body = json.dumps(value).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path == "/api/status":
                    self.reply(200, fake.status())
                    return
                if self.path != "/api/stream":
                    self.reply(404, {"error": "Unknown endpoint"})
                    return
                events = queue.Queue()
                with fake.lock:
                    fake.subscribers.append(events)
                    events.put(dict(fake.status_unlocked(), type="status"))
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ndjson")
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.flush()
                try:
                    while True:
                        try:
                            event = events.get(timeout=0.05)
                        except queue.Empty:
                            event = {"type": "heartbeat"}
                        if event == "TRUNCATE":
                            self.wfile.write(b'{"type": "sample", "counts":')
                            self.wfile.flush()
                            self.close_connection = True
                            return
                        self.wfile.write(json.dumps(event).encode() + b"\n")
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                finally:
                    with fake.lock:
                        fake.subscribers.remove(events)

            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
                with fake.lock:
                    fake.posts.append(self.path)
                    if self.path == "/api/start":
                        if fake.running:
                            self.reply(409, {"error": "Counter is busy"})
                            return
                        fake.running = True
                        fake.starts += 1
                        fake.session = "mock-session" if fake.starts == 1 else "mock-session-" + str(fake.starts)
                        fake.sample_count = 0
                        fake.gate = payload["gate_seconds"]
                        fake.stop_event = threading.Event()
                        state = fake.status_unlocked()
                    elif self.path == "/api/stop":
                        if "session_id" in payload and payload["session_id"] != fake.session:
                            self.reply(409, {"error": "Measurement session changed"})
                            return
                        fake.stop_event.set()
                        state = fake.status_unlocked()
                    else:
                        self.reply(404, {"error": "Unknown endpoint"})
                        return
                self.reply(202, state)
                if self.path == "/api/start":
                    fake.worker = threading.Thread(target=fake.acquire, args=(payload,), daemon=True)
                    fake.worker.start()

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.http.daemon_threads = True
        self.port = self.http.server_address[1]
        self.server = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.server.start()

    def status_unlocked(self):
        return {"running": self.running, "checking": False, "connected": True,
                "status": "測定中" if self.running else "測定終了", "error": "",
                "session_id": self.session, "sample_count": self.sample_count,
                "selected_gate": "0.1秒", "active_gate": "0.1秒", "csv_file": "/mock/native.csv",
                "api_key": "TEST_SECRET_DO_NOT_PRINT", "nested": {"authorization": "Bearer TEST_SECRET_DO_NOT_PRINT"}}

    def status(self):
        with self.lock:
            return self.status_unlocked()

    def broadcast(self, event):
        with self.lock:
            for subscriber in self.subscribers:
                subscriber.put(event)

    def acquire(self, payload):
        self.broadcast(dict(self.status(), type="status"))
        duration = payload.get("duration_seconds")
        limit = round(duration / self.gate) if duration else 10000
        if self.mode == "short":
            limit = 2
        for sequence in range(1, limit + 1):
            if self.stop_event.wait(0.015):
                break
            if self.mode == "truncated" and sequence == 3:
                self.broadcast("TRUNCATE")
                break
            with self.lock:
                self.sample_count = sequence
                if self.mode == "swap" and sequence == 3:
                    self.session = "external-session"
            if self.mode == "gap" and sequence == 2:
                continue
            value = 0xFFFFFFFF if sequence % 2 else 0x92345678
            self.broadcast({"type": "sample", "session_id": self.session, "sample": sequence,
                            "counts": value, "gate_seconds": self.gate, "counts_per_second": value / self.gate,
                            "received_at": "2026-10-09T00:00:00.123Z", "received_unix_seconds": 1791504000.125 + sequence / 1000,
                            "received_monotonic_seconds": 12345 + sequence / 1000,
                            "elapsed_gate_seconds": sequence * self.gate})
        with self.lock:
            self.running = False
        final = dict(self.status(), type="status")
        if self.mode == "error":
            final["error"] = "mock failure secret_token=TEST_SECRET_DO_NOT_PRINT"
        self.broadcast(final)

    def close(self):
        self.stop_event.set()
        if self.worker:
            self.worker.join(timeout=2)
        self.http.shutdown()
        self.http.server_close()
        self.server.join(timeout=2)


class CLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="c8855-cli-build-")
        cls.root = pathlib.Path(__file__).resolve().parents[1]
        cls.cli = pathlib.Path(cls.build.name) / "c8855_counter"
        subprocess.run(["xcrun", "clang++", "-std=c++17", "-O1", "-Wall", "-Wextra", "-Wpedantic", "-Werror",
                        "-I" + str(cls.root / "include"), "-I" + str(cls.root / "vendor"),
                        str(cls.root / "c8855_client.cpp"), str(cls.root / "counter_cli.cpp"),
                        "-lcurl", "-pthread", "-o", str(cls.cli)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="c8855-cli-data-")
        self.output = pathlib.Path(self.directory.name) / "raw.csv"
        self.api = FakeAPI()

    def tearDown(self):
        self.api.close()
        self.directory.cleanup()

    def run_cli(self, *args):
        return subprocess.run([str(self.cli), *args, "--port", str(self.api.port)], capture_output=True, text=True, timeout=15)

    def rows(self):
        with self.output.open(newline="") as file:
            return list(csv.DictReader(file))

    def test_read_only_status_settings_and_no_secret_output(self):
        for command in ["status", "settings"]:
            result = self.run_cli(command)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("TEST_SECRET_DO_NOT_PRINT", result.stdout + result.stderr)
            self.assertIn("[redacted]", result.stdout)
        self.assertEqual(self.api.posts, [])

    def test_start_stop_and_busy_record_preserves_existing_session(self):
        self.assertEqual(self.run_cli("start", "--gate", "0.1").returncode, 0)
        result = self.run_cli("record", "--samples", "3", "--csv", str(self.output))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.api.running)
        self.assertNotIn("/api/stop", self.api.posts)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.run_cli("stop").returncode, 0)
        self.assertFalse(self.api.running)
        self.assertIn("/api/stop", self.api.posts)

    def test_record_duration_preserves_uint32_gate_timestamps_and_blocks(self):
        result = self.run_cli("record", "--gate", "0.01", "--duration", "1", "--csv", str(self.output))
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.rows()
        self.assertEqual(len(rows), 100)
        self.assertEqual([int(row["sample"]) for row in rows], list(range(1, 101)))
        self.assertEqual(int(rows[0]["counts"]), 0xFFFFFFFF)
        self.assertEqual(int(rows[1]["counts"]), 0x92345678)
        self.assertEqual(float(rows[0]["gate_seconds"]), 0.01)
        self.assertEqual(float(rows[0]["counts_per_second"]), 0xFFFFFFFF / 0.01)
        self.assertEqual(rows[0]["received_at"], "2026-10-09T00:00:00.123Z")
        self.assertGreater(float(rows[-1]["received_monotonic_seconds"]), float(rows[0]["received_monotonic_seconds"]))
        self.assertEqual(rows[-1]["nominal_block"], "10")
        self.assertEqual(rows[-1]["nominal_index_in_block"], "10")
        self.assertEqual(rows[0]["session_id"], "mock-session")
        self.assertFalse(self.api.running)

    def test_sample_limit_stops_own_session_and_retains_delivered_samples(self):
        result = self.run_cli("record", "--samples", "5", "--csv", str(self.output))
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.rows()
        self.assertGreaterEqual(len(rows), 5)
        self.assertEqual(len(rows), self.api.sample_count)
        self.assertFalse(self.api.running)

    def test_csv_overwrite_and_invalid_options_do_not_start(self):
        self.output.write_text("keep\n")
        result = self.run_cli("record", "--samples", "5", "--csv", str(self.output))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(), "keep\n")
        for args in [("--gate", "0.001"), ("--duration", "nan"), ("--samples", "-1"), ("--samples", "5junk")]:
            result = self.run_cli("record", *args, "--csv", str(self.output))
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.api.posts, [])

    def test_early_finish_is_partial_failure(self):
        self.api.mode = "short"
        result = self.run_cli("record", "--samples", "10", "--csv", str(self.output))
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(len(self.rows()), 2)
        self.assertIn('"complete":false', result.stderr)

    def test_missing_sample_and_truncated_stream_fail_and_keep_partial_csv(self):
        for mode in ["gap", "truncated"]:
            with self.subTest(mode=mode):
                self.api.mode = mode
                result = self.run_cli("record", "--samples", "10", "--csv", str(self.output))
                self.assertNotEqual(result.returncode, 0)
                self.assertGreater(len(self.rows()), 0)
                self.assertFalse(self.api.running)
                self.output.unlink()

    def test_error_message_does_not_print_secret(self):
        self.api.mode = "error"
        result = self.run_cli("record", "--duration", "1", "--csv", str(self.output))
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("TEST_SECRET_DO_NOT_PRINT", result.stdout + result.stderr)
        self.assertIn("[redacted]", result.stderr)

    def test_session_change_leaves_new_measurement_running(self):
        self.api.mode = "swap"
        result = self.run_cli("record", "--samples", "10", "--csv", str(self.output))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("session changed", result.stderr)
        self.assertTrue(self.api.running)
        self.assertNotIn("/api/stop", self.api.posts)
        self.assertEqual(len(self.rows()), 2)

    def test_ctrl_c_retains_partial_csv_and_stops_own_session(self):
        process = subprocess.Popen([str(self.cli), "record", "--samples", "1000", "--csv", str(self.output), "--port", str(self.api.port)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 5
        while not self.output.exists() or len(self.rows()) < 3:
            if time.monotonic() > deadline:
                process.kill()
                self.fail("Record did not start")
            time.sleep(0.02)
        process.send_signal(signal.SIGINT)
        output, error = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 130, output + error)
        self.assertGreaterEqual(len(self.rows()), 3)
        self.assertFalse(self.api.running)


if __name__ == "__main__":
    unittest.main()
