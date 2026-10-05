"""Python reference used only for protocol tests; not the Mac app."""
import csv
import io
import math
import threading
from datetime import datetime
from pathlib import Path
from counter import USB, Counter, CounterError, GATES
ROOT = Path(__file__).resolve().parent

class Session:
    def __init__(self):
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread = None
        self.rows = []
        self.status = "USB接続を確認してください。カウント精度は検証前の試作版です。"
        self.error = ""
        self.file = ""
        self.running = False

    def snapshot(self):
        with self.lock:
            return dict(running=self.running, status=self.status, error=self.error,
                        rows=self.rows[-600:], count=len(self.rows), file=self.file)

    def probe(self):
        with self.lock:
            if self.running:
                raise CounterError("測定中です。先に停止してください。")
            usb = USB()
            try:
                devices = usb.devices()  # USB enumeration only: no counter command.
            finally:
                usb.close()
            self.status = ("C8855-01を検出しました。測定開始を押してください。" if len(devices) == 1
                           else f"C8855-01検出数: {len(devices)}。1台だけ接続してください。")
            self.error = ""
            return devices

    def start(self, gate, duration):
        if gate not in GATES or not math.isfinite(duration) or not 1 <= duration <= 3600:
            raise CounterError("測定条件が不正です。時間は1〜3600秒で指定してください。")
        with self.lock:
            if self.running:
                raise CounterError("測定はすでに動いています。")
            self.running, self.error, self.rows = True, "", []
            self.file = ""
            self.status = "接続・測定準備中…"
            self.stop_event.clear()
            self.thread = threading.Thread(target=self.worker, args=(gate, duration), daemon=True)
            self.thread.start()

    def worker(self, gate, duration):
        usb = counter = None
        try:
            usb = USB()
            usb.devices(open_device=True)
            counter = Counter(usb)
            folder = ROOT / "measurements"
            folder.mkdir(exist_ok=True)
            path = folder / (datetime.now().strftime("%Y%m%d_%H%M%S_%f") + ".csv")
            with path.open("x", newline="", encoding="utf-8") as stream:
                writer = csv.writer(stream)
                writer.writerow(["received_at", "sample", "gate_seconds", "counts", "counts_per_second"])
                with self.lock:
                    self.file = str(path)
                counter.start(gate)
                with self.lock:
                    self.status = "測定中"
                total = math.ceil(duration / GATES[gate][1])
                for i in range(total):
                    if self.stop_event.is_set():
                        break
                    count = counter.read_count()
                    seconds = GATES[gate][1]
                    row = dict(received_at=datetime.now().astimezone().isoformat(),
                               sample=i + 1, gate_seconds=seconds, counts=count, cps=count / seconds)
                    writer.writerow([row["received_at"], i + 1, seconds, count, row["cps"]])
                    stream.flush()
                    with self.lock:
                        self.rows.append(row)
        except Exception as exc:
            with self.lock:
                self.error = str(exc)
        finally:
            if counter:
                try:
                    counter.stop()
                except Exception as exc:
                    with self.lock:
                        self.error += (" / " if self.error else "") + "停止確認に失敗: " + str(exc)
            if usb:
                usb.close()
            with self.lock:
                self.running = False
                self.status = "測定終了" if not self.error else "測定を中止しました"

    def csv_data(self):
        with self.lock:
            rows = list(self.rows)
        stream = io.StringIO(newline="")
        writer = csv.writer(stream)
        writer.writerow(["received_at", "sample", "gate_seconds", "counts", "counts_per_second"])
        for row in rows:
            writer.writerow([row["received_at"], row["sample"], row["gate_seconds"], row["counts"], row["cps"]])
        return stream.getvalue().encode("utf-8-sig")

