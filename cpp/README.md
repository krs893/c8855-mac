# C8855 C++クライアント

C++17からMacアプリのAPIを使い、開始・停止・カウントの連続受信を行います。
**実行時にPythonは使いません。** C8855 Macアプリv0.4.0以上を起動してください。

## すぐ使う

[Release](https://github.com/krs893/c8855-mac/releases/latest)のC++クライアントZIPに、Apple Silicon / Intel共通の実行ファイルを同梱しています。macOS 13以上です。
解凍したフォルダーで：

```sh
./c8855_realtime --status
./c8855_realtime --gate 0.1 --seconds 10
```

アプリで「API受付中」とUSB接続済みを確認してください。
SPADの信号・電源は別途接続します。0.1秒ゲートで10秒間受信し、CSVはアプリ側で保存します。
連続測定は `--continuous`。Ctrl+Cで停止を要求し、停止完了まで受信します。
`--json`を付けると各sampleを1行のJSONで出力します。`--stop`は現在の測定を停止します。
公証は未取得です。起動を拒否される場合は、入手元を確認してmacOSの許可操作を行うか、同梱ソースからビルドしてください。

## 自分でビルド

Xcodeの開発ツールがあれば、CMakeや追加パッケージなしでもビルドできます。
macOS SDKのlibcurlと、同梱nlohmann/jsonを使います。

```sh
xcrun clang++ -std=c++17 -O2 -mmacosx-version-min=13.0 \
  -Iinclude -Ivendor c8855_client.cpp example_realtime.cpp \
  -lcurl -pthread -o c8855_realtime
```

CMakeを使う場合：

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/c8855_realtime --gate 0.1 --seconds 10
```

## コマンド別のCLI（ソース版）

`c8855_counter` は同じC++クライアントを使い、状態確認・開始・停止・CSV記録をコマンドに分けた実行ファイルです。実行時にPythonは不要です。この追加CLIは既存のRelease ZIPへの同梱をまだ確認していません。

ソースフォルダーでは次の起動スクリプトも使えます。

```sh
./counter_cli.sh --help
./counter_cli.sh status
./counter_cli.sh record --gate 0.01 --samples 100 --csv counts.csv
```

初回だけC++17・macOS標準libcurlでビルドし、`~/Library/Caches/dev.lab.c8855/`に保存します。ソース・ヘッダー・vendorの変更時は再ビルドします。アプリやUSBは自動起動しません。`status`／`record`の前にMacアプリを起動してください。手動ビルドする場合：

```sh
xcrun clang++ -std=c++17 -O2 -mmacosx-version-min=13.0 \
  -Iinclude -Ivendor c8855_client.cpp counter_cli.cpp \
  -lcurl -pthread -o /tmp/c8855_counter

/tmp/c8855_counter status
/tmp/c8855_counter settings
/tmp/c8855_counter record --gate 0.01 --duration 10 --csv counts.csv
/tmp/c8855_counter record --gate 0.01 --samples 100 --csv counts-100.csv
```

CMakeでも `c8855_counter` を同時にビルドします。`settings` は対応する計数時間と現在の設定を読む操作で、設定を書き換えません。計数時間の指定は `start` または `record --gate` で行います。`status` と `settings` は測定を開始・停止せず、USB接続確認命令も送りません。

CSV記録せず測定を開始・停止する場合：

```sh
/tmp/c8855_counter start --gate 0.1 --duration 10
/tmp/c8855_counter start --gate 0.1    # 停止するまで連続
/tmp/c8855_counter stop
```

`start` の返答は要求受付です。アプリの `status` で実際の開始・USBエラーを確認してください。アプリ側の自動CSV保存はこれらのコマンドでも続きます。

### CSVと終了条件

- `record` は `--duration`（名目の総計数時間、1〜3600秒）か `--samples`（停止を要求する取得点数）の一方と、`--csv` を指定します。既存ファイルは上書きしません。
- `--samples` 到達後は停止完了まで届いた点もすべて保存するため、100 msのUSBバッチによって指定点数を超える場合があります。保存した実際の点数は終了時に表示します。`--duration` もUSB受信・停止待ちを含む実時間とは異なります。
- 生の整数カウント、計数時間、counts/s、ISO／Unix／単調時計の受信時刻、取得番号、セッションID、名目の累積計数時間を保存します。PDE・デッドタイム・背景の補正はしません。
- `nominal_block`、`nominal_index_in_block`、`nominal_block_size` は計数時間と取得番号から求めた**名目の**USBまとめ受信の番号です。ハードウェアの転送IDや光子到着時刻ではありません。受信時刻からゲート開始を推定して埋めることもしません。
- 点の欠落・重複、通信切断、不正データ、途中のセッション変更はエラーにします。CSVは途中までの実データとして残し、0カウントや架空の行で埋めません。指定数に達しない正常終了も終了コード3で通知します。
- Ctrl+Cは自分が開始したセッションへ停止を要求し、到着済みの点を保存して終了コード130で終わります。既存の測定中は `record` の開始を拒否します。別のセッションへ変わった場合は、その新しい測定へ停止要求を送りません。

画面とCLIは同じ測定を操作するため、測定中の設定変更・再開は一方からだけ行ってください。既存APIの停止要求はセッションIDを引数に取らないので、状態確認と停止の間に別の操作者が再開する競合を完全には防げません。

### 接続と認証

USBはMacアプリが所有します。先に `C8855カウンター.app` を起動し、API受付中・USB接続済みを確認してください。CLIからアプリを自動起動したり、USBを直接開いたりはしません。接続できない場合はアプリを起動して `status` を再実行します。

接続先は `127.0.0.1` のみ。通常は8855番、別ポートのテストは `--port` を使います。`--timeout-ms` は接続・停止待ち等の期限です。現APIには認証トークン・認証設定ファイルはありません。既存のlocalhost／Host／Origin制限をそのまま使います。状態出力に認証情報らしい項目が追加された場合は伏せて表示します。

### CLIの検証

```sh
python3 -m unittest discover -s tests -p 'test_cli.py' -v
```

テストのPythonはHTTP模擬サーバーとビルドの実行だけに使います。CLIの状態確認・開始停止・32 bitカウントとCSV、指定点数、早期終了、欠落、切断、Ctrl+C、既存計測の保持、秘密情報の非表示を検証します。通常アプリの8855番ポートや実機USBには接続しません。

## 視線計測コードに組み込む

- `include/c8855_client.hpp`：公開インターフェース。
- `c8855_client.cpp`：HTTP通信・受信スレッド・JSON処理。
- `example_realtime.cpp`：開始、受信、停止、エラー処理の実行例。
- CMakeの`c8855_client`ターゲットを自分のプログラムにリンクできます。

```cpp
c8855::Client counter;
auto stream = counter.stream();         // 先に受信経路を開く
auto state = counter.start(0.1, 10.0);   // 0.1秒ゲート、10秒間
```

`stream.next()`でstatus / sample / heartbeatを取得します。sampleは：

```cpp
auto sample = c8855::Sample::from_event(event);
// sample.counts                 : uint32_t、1回のカウント
// sample.counts_per_second      : 毎秒のカウント
// sample.received_unix_seconds  : Mac側の受信時刻
// sample.sequence               : セッション内の取得番号
// sample.session_id             : 開始ごとのID
```

`example_realtime.cpp`のコメントがある処理箇所へ、視線推定処理を入れてください。
`Client::status()`、`probe()`、`start()`、`stop()`をコードから呼べます。
`start()`の返答は要求の受付です。実際のUSB操作の失敗はstatusイベントで確認します。
`stop()`は既定で停止完了まで待ちます。`stop(false)`は停止要求だけを送ります。

## 受信と時刻

受信は専用スレッドで行い、最大256イベントをキューへ保持します。`next()`はイベントが来るまで待つので、画面の描画ループから直接呼ばず、計測用の処理ループで使ってください。
読み取りが追いつかない、JSONが不正、通信が切断された場合は例外で通知します。勝手な再接続や値の補完は行いません。
ストリームを閉じるだけでは測定は止まりません。アプリのCSV保存は独立して続きます。
画面とAPIは同じ測定を操作します。取得番号・セッションIDを確認してください。

最短計数時間は10 msです。10点を約100 msごとにまとめてUSB受信し、全点をCSVとAPIへ出力します。画面の更新は約100 msごとです。
受信時刻は光子到着時刻・ゲート開始時刻ではなく、画面の切り替え時刻は実験コード側でも記録する必要があります。
詳細は[API仕様](../API.md)を参照してください（配布ZIPではAPI.md）。

## 検証・ライセンス

実際の測定モデルとAPIに模擬USBをつなぎ、C++での受信とCSV一致、32 bit整数の保持、Ctrl+Cでの停止、測定中の開始拒否を検証済みです。
非ゼロの実機精度、同期精度、Intel実機の動作は未検証です。

クライアントはMIT。nlohmann/json v3.12.0はMITで、`vendor/nlohmann/LICENSE.MIT`を同梱します。
libcurlはmacOSのシステムライブラリを動的に利用します。
依存ライブラリの公式資料：[libcurl](https://curl.se/libcurl/)、[nlohmann/json](https://json.nlohmann.me/)。

10 ms設定は `--gate 0.01` / `gate_seconds: 0.01` で指定できます。受信時刻は各ゲートの計測時刻ではなく、同一ブロックの点はほぼ同じ受信時刻になります。50 µs〜5 msの設定はこの版では未対応です。
