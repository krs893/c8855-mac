# 視線計測コードとの連携

アプリを起動すると、同じMac上のプログラム向けに `http://127.0.0.1:8855/api` を開きます。
左側に「API受付中」と表示されていることを確認してください。
カウンターのUSBはアプリが読み取ります。外部コードはAPIを使い、USBを直接開かないでください。

## Pythonで受信する

追加のPythonパッケージは不要です。このフォルダーで：

```sh
python3 example_realtime.py --gate 0.1 --seconds 10
```

アプリでUSB接続を確認してから実行します。SPADの信号・電源も別途接続してください。
10秒間のカウントを連続受信し、アプリがCSVに自動保存します。
コードへの組み込み例：

```python
from counter_client import CounterClient

counter = CounterClient()
with counter.stream() as events:     # 先に受信経路を開く
    state = counter.start(gate_seconds=0.1, duration_seconds=10)
    session = state["session_id"]
    try:
        for event in events:
            if event.get("session_id") != session:
                continue
            if event["type"] == "sample":
                counts = event["counts"]
                received_time = event["received_unix_seconds"]
                # ここで視線計測コードへcountsとreceived_timeを渡す
            elif event["type"] == "status" and not event["running"]:
                if event["error"]:
                    raise RuntimeError(event["error"])
                break
    finally:
        if counter.status()["session_id"] == session:
            counter.stop()
```

測定時間を指定しなければ停止するまで連続測定します。
画面とAPIは同じ測定を操作します。他のコードや画面からの停止・変更も反映されます。
`POST /api/start`の202応答は開始要求の受付です。USB操作の成功・失敗は後続のstatusで確認してください。

## エンドポイント

| メソッド | パス | 内容 |
| --- | --- | --- |
| GET | `/api/status` | 接続、測定状態、最新値、保存先、セッションID |
| GET | `/api/stream` | NDJSONでstatus / sample / heartbeatを連続受信 |
| POST | `/api/probe` | `{}`でUSB接続確認。測定中は409 |
| POST | `/api/start` | `{"gate_seconds":0.1,"duration_seconds":10}`で開始 |
| POST | `/api/stop` | `{}`で停止を要求。完了はstatusで確認 |

POSTは`Content-Type: application/json`必須。計数時間は0.1 / 0.2 / 0.5 / 1秒。
測定時間は省略で連続、指定時は1〜3600秒。測定中の開始要求は409です。
設定を変える場合は停止完了を待ってから開始します。

## sampleの値

| フィールド | 意味 |
| --- | --- |
| `session_id` | 開始ごとに変わるID。設定変更・再開でも変わる |
| `sample` | セッション内の取得番号、1から始まる |
| `counts` | 1回の計数時間に取得した整数カウント |
| `counts_per_second` | counts ÷ gate_seconds |
| `gate_seconds` | 設定した計数時間 |
| `received_at` | Mac側の受信時刻、ISO 8601形式 |
| `received_unix_seconds` | 同じ受信時刻、Unix秒（画面表示ログとの照合用） |
| `received_monotonic_seconds` | Mac側の単調時計。セッション内の受信間隔を見るための値 |
| `elapsed_gate_seconds` | 取得番号 × 計数時間。実際のUSB受信間隔ではない |

## リアルタイム計測の範囲

- 最短0.1秒の計数時間ごとにデータを送ります。USB・保存処理による追加遅延があります。
- 受信時刻は光子到着時刻・ゲート開始時刻ではありません。画面の切り替え時刻を実験側でも記録し、応答の遅延を測ってください。厳密な表示同期は未実装です。
- heartbeatは約2秒ごと。計測値ではありません。
- 接続時はstatusを返し、その後の新規データを送ります。過去のsampleを再送しません。
- 受信が遅いクライアントは切断します。取得番号の欠落やセッション変更を確認してください。アプリのCSV保存は独立して続きます。
- ストリームを閉じるだけでは測定は停止しません。停止要求の完了まで確認してください。
- このMac内だけに接続できます。ブラウザーからの要求と外部Hostを拒否します。他のローカルプログラムからは測定を操作できます。
- 8855番ポートを使えない場合、APIは起動しません。画面の測定は使えます。

## 検証

2026-10-06、実際のアプリの測定モデル・API・Pythonクライアントを使い、模擬USBで開始・連続受信・停止・CSV一致・不正設定拒否を確認しました。模擬データは実験値ではありません。
非ゼロの実機カウント精度と画面表示との同期精度は未検証です。
