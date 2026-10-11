import Cocoa
import SwiftUI
import UniformTypeIdentifiers

struct CounterView: View {
    @ObservedObject var model: CounterModel
    @State private var showIntegration = false
    private var unit: String { model.rateDisplay ? "counts/s" : "counts" }
    private var durationValid: Bool {
        guard let value = Double(model.duration) else { return false }
        return value.isFinite && (1...3600).contains(value)
    }
    private var recordingTitle: String {
        if model.savedURL == nil { return "CSVと測定条件を自動保存" }
        if model.running { return "測定データを記録中" }
        return model.error.isEmpty ? "測定記録を保存しました" : "測定終了 · エラー内容を確認してください"
    }
    private var manualValid: Bool {
        guard let value = Double(model.manualMaximum) else { return false }
        return value.isFinite && value > 0
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("C8855-01").font(.system(size: 20, weight: .semibold))
                Divider().frame(height: 22)
                Circle().fill(model.running ? Color.green : (model.connected ? Color.green : Color.secondary)).frame(width: 7, height: 7)
                Text(model.checking ? "接続を確認中…" : (model.running ? "測定中" : (model.connected ? "USB接続済み" : "未接続")))
                    .font(.callout).foregroundColor(.secondary)
                Spacer()
                Button { model.showHelp = true } label: { Image(systemName: "questionmark.circle").font(.title3) }
                    .buttonStyle(.plain).help("接続と操作の説明").accessibilityLabel("使い方")
                Button(action: model.start) { Label("測定開始", systemImage: "play.fill").frame(width: 96) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.running || model.checking || !model.connected || (!model.continuous && !durationValid))
                Button(action: model.stop) { Label("停止", systemImage: "stop.fill").frame(width: 64) }
                    .controlSize(.large).disabled(!model.running).keyboardShortcut(".", modifiers: .command)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 256)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    if !model.error.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.status).font(.callout).bold().lineLimit(2)
                                Text(model.error).font(.caption).textSelection(.enabled).lineLimit(3).help(model.error)
                            }
                            Spacer()
                        }.padding(12).background(Color.orange.opacity(0.09)).cornerRadius(6)
                    }
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.rateDisplay ? "毎秒のカウント" : "1区間のカウント").font(.callout).foregroundColor(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(model.latest.map { String(format: model.rateDisplay ? "%.1f" : "%.0f", $0.value(rate: model.rateDisplay)) } ?? "—")
                                    .font(.system(size: 44, weight: .medium, design: .monospaced)).monospacedDigit()
                                    .lineLimit(1).minimumScaleFactor(0.6)
                                Text(unit).font(.callout).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 7) {
                            Text(model.running ? model.status : (model.samples.isEmpty ? "測定待ち" : model.status))
                                .font(.callout).foregroundColor(model.running ? .green : .secondary)
                                .lineLimit(2)
                            Text(model.latest.map { "\(String(format: "%g", $0.seconds))秒間に \(String($0.counts)) カウント" } ?? "出力パルスを数えて表示します")
                                .font(.caption).foregroundColor(.secondary)
                            Text("\(model.sampleCount)回取得").font(.caption).monospacedDigit().foregroundColor(.secondary)
                        }.frame(width: 186, alignment: .trailing)
                    }.frame(height: 92, alignment: .bottom)
                    HStack {
                        Text("カウントの推移").font(.callout).bold()
                        Spacer()
                        Button {
                            model.freeze.toggle(); model.freezeChanged()
                        } label: {
                            Label(model.freeze ? "表示を再開" : "表示を固定", systemImage: model.freeze ? "play.fill" : "pause.fill")
                        }.disabled(model.samples.isEmpty).help("グラフだけを固定します。測定と保存は続きます。")
                    }
                    CountPlot(rows: model.plotRows, window: model.windowSeconds,
                              maximum: PlotData.maximum(model.plotRows, rate: model.rateDisplay, automatic: model.automaticScale, manual: model.manualMaximum),
                              rate: model.rateDisplay, emptyMessage: model.connected ? "「測定開始」でグラフを表示" : "カウンターをUSBで接続してください")
                        .frame(minHeight: 220)
                    HStack(spacing: 6) {
                        if model.freeze { Image(systemName: "pause.fill").foregroundColor(.orange) }
                        Text(model.freeze ? (model.running ? "表示固定中 · 測定とCSV保存は継続" : "表示固定中 · 測定は終了") : "横軸：計数時間の累積 · 個々のパルス波形ではありません")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "doc.text").foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(recordingTitle)
                        .font(.callout)
                    Text(model.savedURL?.lastPathComponent ?? "測定を開始すると記録を作成します")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Button("保存フォルダー", action: model.openDataFolder)
                Button("記録を書き出す…", action: model.export).disabled(model.running || model.samples.isEmpty)
                    .help("CSVと測定条件のファイルを一緒に書き出します")
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }.frame(minWidth: 980, minHeight: 650)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { model.probe() }
            .sheet(isPresented: $model.showHelp) { helpSheet }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("USB接続").font(.callout).bold()
                        Spacer()
                        Button("再確認", action: model.probe).disabled(model.running || model.checking)
                            .controlSize(.small)
                    }
                    Text(model.connectionDetail).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("測定条件").font(.callout).bold()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.running ? "次の計数時間" : "1区間の計数時間").font(.caption).foregroundColor(.secondary)
                        Picker("1区間の計数時間", selection: $model.gate) {
                            ForEach(model.gates, id: \.self) { Text($0) }
                        }.labelsHidden().disabled(model.checking)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.activeGate.isEmpty ? "設定した時間ごとにカウントを取得" :
                                 "\(model.running ? "実行中" : "前回")：\(model.activeGate)")
                                .font(.caption).monospacedDigit().foregroundColor(.secondary)
                            if model.running && model.gate != model.activeGate {
                                Button("変更して再開", action: model.applyGate)
                                    .help("現在の記録を保存して、選んだ計数時間で新しい測定を開始します")
                            } else {
                                Text(model.running ? "時間を選び直すと変更できます" : "短い区間ほど素早く更新します")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }.frame(height: 48, alignment: .topLeading)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("終了方法").font(.caption).foregroundColor(.secondary)
                        Picker("終了方法", selection: $model.continuous) {
                            Text("手動で停止").tag(true); Text("時間を指定").tag(false)
                        }.labelsHidden().disabled(model.running)
                        HStack {
                            Text("測定時間").font(.caption)
                            Spacer()
                            TextField("秒", text: $model.duration).textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing)
                                .frame(width: 72).accessibilityLabel("測定時間（秒）")
                                .disabled(model.running || model.continuous)
                            Text("秒").font(.caption).foregroundColor(.secondary)
                        }
                        Text(!model.continuous && !durationValid ? "1〜3600秒を入力してください" :
                             (model.continuous ? "「停止」を押すまで測定します" : "指定時間で自動停止します（1〜3600秒）"))
                            .font(.caption2).foregroundColor(!model.continuous && !durationValid ? .orange : .secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("グラフ表示").font(.callout).bold()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("横軸の表示範囲").font(.caption).foregroundColor(.secondary)
                        Picker("横軸の表示範囲", selection: $model.windowSeconds) {
                            Text("直近10秒").tag(10.0); Text("直近30秒").tag(30.0); Text("直近60秒").tag(60.0)
                        }.labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("表示する値").font(.caption).foregroundColor(.secondary)
                        Picker("表示する値", selection: $model.rateDisplay) {
                            Text("毎秒のカウント").tag(true); Text("1区間のカウント").tag(false)
                        }.labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("縦軸を自動調整", isOn: $model.automaticScale).toggleStyle(.checkbox).font(.caption)
                        HStack {
                            Text("上限").font(.caption)
                            TextField("上限", text: $model.manualMaximum).textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced)).multilineTextAlignment(.trailing)
                                .accessibilityLabel("縦軸の上限").disabled(model.automaticScale)
                            Text(unit).font(.caption2).foregroundColor(.secondary).frame(width: 45, alignment: .leading)
                        }
                        if !model.automaticScale && !manualValid {
                            Text("正の数を入力してください。現在は自動調整です。")
                                .font(.caption2).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider()
                DisclosureGroup("外部コードとの連携", isExpanded: $showIntegration) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.apiReady ? "API受付中 · 127.0.0.1:8855" : (model.apiDetail == "準備中" ? "API準備中" : "APIを利用できません"))
                            .font(.caption).foregroundColor(model.apiReady ? .secondary : .orange)
                        if !model.apiReady { Text(model.apiDetail).font(.caption2).foregroundColor(.secondary) }
                    }.padding(.top, 6).fixedSize(horizontal: false, vertical: true)
                }.font(.caption)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private var helpSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("接続と測定").font(.title2).bold()
            Text("1. C8855-01をUSBでMacに接続\n2. SPADのSIGNALをカウンターのSIG INへ接続\n3. 接続を確認し、「測定開始」を押す")
                .font(.body).lineSpacing(8)
            Divider()
            Text("SPADの電源は別途±5 Vが必要です。カウンターのDC OUTをSPAD電源に接続しないでください。")
            Text("計数時間を変更したら「変更して再開」を押します。表示の固定は測定を止めません。「停止」で計数を終了します。")
            Text("CSVと測定条件を自動保存します。「保存フォルダー」で確認し、停止後に「記録を書き出す…」で両方をコピーできます。")
            Divider()
            Text("外部コード連携：このアプリを起動したまま、同じMac上のPythonコードなどからAPIで開始・停止・カウントの連続受信ができます。接続先は127.0.0.1:8855です。")
                .font(.caption)
            Text("メーカー非公式 · v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")").font(.caption).foregroundColor(.secondary)
            Text("USB通信は確認済み。非ゼロの計数精度、長時間測定、表示・点灯との同期は実機での確認が必要です。")
                .font(.caption).foregroundColor(.secondary)
            HStack { Spacer(); Button("閉じる") { model.showHelp = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 510)
    }
}

struct CountPlot: View {
    let rows: [Sample]
    let window: Double
    let maximum: Double
    let rate: Bool
    let emptyMessage: String
    private let trace = Color(red: 0.23, green: 0.86, blue: 0.69)
    var body: some View {
        GeometryReader { geo in
            let end = rows.last?.elapsed ?? 0
            let start = max(0, end - window)
            let left = 66.0, top = 26.0
            let width = max(1, geo.size.width - left - 24)
            let height = max(1, geo.size.height - top - 42)
            ZStack(alignment: .topLeading) {
                Color(red: 0.07, green: 0.09, blue: 0.10)
                Path { p in
                    for i in 0...5 {
                        let x = left + Double(i) / 5 * width
                        p.move(to: CGPoint(x: x, y: top)); p.addLine(to: CGPoint(x: x, y: top + height))
                        let y = top + Double(i) / 5 * height
                        p.move(to: CGPoint(x: left, y: y)); p.addLine(to: CGPoint(x: left + width, y: y))
                    }
                }.stroke(Color.white.opacity(0.13), lineWidth: 0.5)
                ForEach(0...5, id: \.self) { i in
                    Text(String(format: "%.3g", maximum * (1 - Double(i) / 5)))
                        .frame(width: 52, alignment: .trailing)
                        .position(x: 30, y: top + Double(i) / 5 * height)
                    Text(String(format: "%g", start + Double(i) / 5 * window))
                        .position(x: left + Double(i) / 5 * width, y: top + height + 18)
                }.font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.5))
                Text(rate ? "counts/s" : "counts").font(.system(size: 10)).foregroundColor(.white.opacity(0.5)).padding(.leading, 12).padding(.top, 7)
                Text("時間 (秒)").font(.system(size: 10)).foregroundColor(.white.opacity(0.5)).position(x: left + width - 24, y: 12)
                Path { p in
                    for (i, row) in rows.enumerated() {
                        let point = CGPoint(x: left + (row.elapsed - start) / window * width,
                                            y: top + height * (1 - PlotData.normalized(row.value(rate: rate), maximum: maximum)))
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }.stroke(trace, lineWidth: 1.7)
                if let last = rows.last {
                    Circle().fill(trace).frame(width: 5, height: 5)
                        .position(x: left + (last.elapsed - start) / window * width,
                                  y: top + height * (1 - PlotData.normalized(last.value(rate: rate), maximum: maximum)))
                }
                if rows.isEmpty {
                    Text(emptyMessage).font(.callout).foregroundColor(.white.opacity(0.65))
                        .frame(width: width, height: height).offset(x: left, y: top)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 6))
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("カウントの時間変化グラフ")
            .accessibilityValue(rows.last.map { "最新値 \($0.value(rate: rate))、表示範囲 \(window)秒" } ?? "未測定")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CounterModel()
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startAPI()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 980, height: 650)
        window.title = "C8855-01 カウンター"
        window.contentView = NSHostingView(rootView: CounterView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        let menu = NSMenu(); let item = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
    }
    func applicationWillTerminate(_ notification: Notification) { model.api.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.running || model.checking else { return .terminateNow }
        model.stop()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if !self.model.running && !self.model.checking { timer.invalidate(); NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

@main
struct CounterApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
