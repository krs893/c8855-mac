"""Exercise the public Python example without an app, USB, or network."""
import contextlib
import io
import unittest
from unittest.mock import patch

import example_realtime


class FakeClient:
    def __init__(self, events, current_session="own"):
        self.events = events
        self.current_session = current_session
        self.stops = []

    @contextlib.contextmanager
    def stream(self):
        yield iter(self.events)

    def start(self, *_):
        return {"session_id": "own"}

    def status(self):
        return {"session_id": self.current_session}

    def stop(self, **kwargs):
        self.stops.append(kwargs)


def sample(sequence, session="own", gate=0.1):
    return {"type": "sample", "session_id": session, "sample": sequence,
            "gate_seconds": gate, "counts": 20}


class ExampleTests(unittest.TestCase):
    def run_example(self, client):
        error = io.StringIO()
        with patch("sys.argv", ["example_realtime.py"]), patch.object(example_realtime, "CounterClient", return_value=client), \
                patch.object(example_realtime, "on_sample") as received, contextlib.redirect_stderr(error):
            result = example_realtime.main()
        return result, received, error.getvalue()

    def test_missing_sample_fails_and_only_stops_own_session(self):
        client = FakeClient([sample(1), sample(3)])
        result, received, error = self.run_example(client)
        self.assertEqual(result, 1)
        self.assertEqual(received.call_count, 1)
        self.assertIn("Missing or duplicate", error)
        self.assertEqual(client.stops, [{"session_id": "own"}])

    def test_session_change_fails_without_stopping_external_measurement(self):
        client = FakeClient([sample(1), sample(1, "external")], "external")
        result, received, error = self.run_example(client)
        self.assertEqual(result, 1)
        self.assertEqual(received.call_count, 1)
        self.assertIn("session changed", error)
        self.assertEqual(client.stops, [])

    def test_normal_completion_ignores_initial_status_and_heartbeat(self):
        client = FakeClient([{"type": "status", "session_id": "preceding"}, {"type": "heartbeat"}, sample(1),
                             {"type": "status", "session_id": "own", "running": False, "error": ""}])
        result, received, error = self.run_example(client)
        self.assertEqual(result, 0, error)
        self.assertEqual(received.call_count, 1)
        self.assertEqual(client.stops, [{"session_id": "own"}])
