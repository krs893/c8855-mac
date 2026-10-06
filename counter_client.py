"""Python client for the native C8855 app. Standard library only."""
import contextlib
import json
import time
import urllib.error
import urllib.request


class CounterAPIError(RuntimeError):
    pass


class CounterClient:
    def __init__(self, port=8855, timeout=10):
        self.base = f"http://127.0.0.1:{int(port)}/api"
        self.timeout = timeout
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def _request(self, endpoint, payload=None):
        request = urllib.request.Request(
            self.base + endpoint,
            data=None if payload is None else json.dumps(payload, allow_nan=False).encode(),
            headers={} if payload is None else {"Content-Type": "application/json"},
        )
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            try:
                message = json.load(error).get("error", str(error))
            except (ValueError, OSError):
                message = str(error)
            error.close()
            raise CounterAPIError(message) from error
        except (urllib.error.URLError, TimeoutError) as error:
            raise CounterAPIError("C8855アプリを起動し、API受付中になっているか確認してください") from error

    def status(self):
        return self._request("/status")

    def probe(self):
        return self._request("/probe", {})

    def start(self, gate_seconds=0.1, duration_seconds=None):
        payload = {"gate_seconds": gate_seconds}
        if duration_seconds is not None:
            payload["duration_seconds"] = duration_seconds
        # 202 means accepted; later status events report USB start failure/completion.
        return self._request("/start", payload)

    def stop(self, wait=True):
        state = self._request("/stop", {})
        if wait:
            deadline = time.monotonic() + self.timeout
            while state["running"]:
                if time.monotonic() >= deadline:
                    raise CounterAPIError("停止処理の完了を確認できませんでした")
                time.sleep(0.05)
                state = self.status()
            if state["error"]:
                raise CounterAPIError(state["error"])
        return state

    @contextlib.contextmanager
    def stream(self):
        """Subscribe BEFORE starting. Yields status/sample/heartbeat dictionaries.

        No automatic restart or replay. EOF raises an error; sample sequence and
        session_id let the caller detect missing data and session changes.
        Closing the subscription alone does NOT stop counting.
        """
        try:
            response = self.opener.open(self.base + "/stream", timeout=self.timeout)
        except (urllib.error.URLError, TimeoutError) as error:
            raise CounterAPIError("カウントの受信を開始できませんでした") from error

        def events():
            while True:
                try:
                    line = response.readline(65537)
                except OSError as error:
                    raise CounterAPIError("リアルタイム受信が切断されました") from error
                if not line or len(line) > 65536 or not line.endswith(b"\n"):
                    raise CounterAPIError("リアルタイム受信が切断されました。再接続時に欠測を確認してください")
                try:
                    yield json.loads(line)
                except ValueError as error:
                    raise CounterAPIError("不正な受信データです") from error
        try:
            yield events()
        finally:
            response.close()
