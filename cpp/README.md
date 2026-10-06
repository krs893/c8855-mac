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

最短間隔は0.1秒です。C++に変えてもゲート時間やUSBの遅延は変わりません。
受信時刻は光子到着時刻・ゲート開始時刻ではなく、画面の切り替え時刻は実験コード側でも記録する必要があります。
詳細は[API仕様](../API.md)を参照してください（配布ZIPではAPI.md）。

## 検証・ライセンス

実際の測定モデルとAPIに模擬USBをつなぎ、C++での受信とCSV一致、32 bit整数の保持、Ctrl+Cでの停止、測定中の開始拒否を検証済みです。
非ゼロの実機精度、同期精度、Intel実機の動作は未検証です。

クライアントはMIT。nlohmann/json v3.12.0はMITで、`vendor/nlohmann/LICENSE.MIT`を同梱します。
libcurlはmacOSのシステムライブラリを動的に利用します。
依存ライブラリの公式資料：[libcurl](https://curl.se/libcurl/)、[nlohmann/json](https://json.nlohmann.me/)。
