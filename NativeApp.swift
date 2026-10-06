import Cocoa
import SwiftUI
import UniformTypeIdentifiers

final class CounterModel: ObservableObject {
    @Published var showHelp = false
    @Published var gate = "1秒"
    @Published var connected = false
    @Published var connectionDetail = "USBでカウンターを接続してください"
    @Published var duration = "10"
    @Published var continuous = true
    @Published var windowSeconds = 30.0
    @Published var rateDisplay = true
    @Published var automaticScale = true
    @Published var manualMaximum = "1000"
    @Published var freeze = false
    @Published var frozenSamples: [Sample] = []
    @Published var sampleCount = 0
    @Published var activeGate = ""
    @Published var running = false
    @Published var checking = false
    @Published var status = "カウンターをUSBで接続し、「接続を確認」を押してください。"
    @Published var error = ""
    @Published var samples: [Sample] = []
    @Published var savedURL: URL?
    private let queue = DispatchQueue(label: "lab.c8855.usb")
    private let lock = NSLock()
    private var stopRequested = false
    private var restartRequested = false
    let gates: [String] = ["1秒", "0.5秒", "0.2秒", "0.1秒"]
    private let settings: [String: (UInt8, Double)] = ["1秒": (15, 1), "0.5秒": (14, 0.5), "0.2秒": (13, 0.2), "0.1秒": (12, 0.1)]
    private var library: String { Bundle.main.resourceURL!.appendingPathComponent("libusb-1.0.dylib").path }
    var latest: Sample? { samples.last }
    var plotRows: [Sample] { PlotData.visible(freeze ? frozenSamples : samples, window: windowSeconds) }
    func freezeChanged() { frozenSamples = freeze ? samples : [] }
    func applyGate() {
        guard running else { return }
        restartRequested = true
        lock.lock(); stopRequested = true; lock.unlock()
        status = "記録を保存し、計数時間を変更しています…"
    }

    func probe() {
        guard !running && !checking else { return }
        checking = true; error = ""
        let path = library
        queue.async {
            var buffer = [CChar](repeating: 0, count: 512)
            let found = c8855_probe(path, &buffer, buffer.count)
            let message = String(cString: buffer)
            DispatchQueue.main.async {
                self.checking = false
                self.connected = found == 1
                self.connectionDetail = found == 1 ? "C8855-01 · USB接続済み" : (found == 0 ? "カウンターが見つかりません。USB接続を確認してください。" : "1台だけ接続してください。")
                if found < 0 { self.error = message; self.status = "接続を確認できませんでした。" }
                else if found == 1 { self.status = "C8855-01を検出しました。測定を開始できます。" }
                else { self.status = "C8855-01検出数：\(found)。1台だけ接続してください。" }
            }
        }
    }

    func stop() {
        restartRequested = false
        lock.lock(); stopRequested = true; lock.unlock()
        if running { status = "停止しています…" }
    }
    private func shouldStop() -> Bool {
        lock.lock(); defer { lock.unlock() }; return stopRequested
    }
    func start() {
        guard !running && !checking, let (code, seconds) = settings[gate] else { return }
        let continuous = continuous
        let duration = continuous ? 10.0 : (Double(duration) ?? .nan)
        guard duration.isFinite, duration >= 1, duration <= 3600 else {
            error = "測定時間は1〜3600秒で入力してください。"; return
        }
        running = true; restartRequested = false; samples = []; sampleCount = 0
        freeze = false; frozenSamples = []; activeGate = gate
        savedURL = nil; error = ""; status = "測定準備中…"
        lock.lock(); stopRequested = false; lock.unlock()
        let path = library
        let dataFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("C8855Counter/measurements")
        queue.async {
            var buffer = [CChar](repeating: 0, count: 512)
            guard let counter = c8855_open(path, &buffer, buffer.count) else {
                let message = String(cString: buffer)
                DispatchQueue.main.async { self.connected = false; self.connectionDetail = "USB接続を確認してください。"; self.error = message; self.status = "測定を開始できません。"; self.running = false; self.restartRequested = false }
                return
            }
            var failure = ""
            var file: FileHandle?
            do {
                try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
                let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
                let url = dataFolder.appendingPathComponent(formatter.string(from: Date()) + "_" + UUID().uuidString.prefix(6) + ".csv")
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                file = try FileHandle(forWritingTo: url)
                try file!.write(contentsOf: Data("received_at,sample,gate_seconds,counts,counts_per_second\n".utf8))
                DispatchQueue.main.async { self.savedURL = url }
                if c8855_start(counter, code, UInt32(seconds * 2000 + 1000)) != 0 {
                    failure = String(cString: c8855_error(counter))
                } else {
                    DispatchQueue.main.async { self.status = "測定中" }
                    let clock = ISO8601DateFormatter(); clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    var i = 0
                    let limit = Int(ceil(duration / seconds))
                    while continuous || i < limit {
                        if self.shouldStop() { break }
                        i += 1
                        var count: UInt32 = 0
                        if c8855_read(counter, &count) != 0 { failure = String(cString: c8855_error(counter)); break }
                        let row = Sample(id: i, received: clock.string(from: Date()), seconds: seconds, counts: count)
                        let line = "\(row.received),\(i),\(seconds),\(count),\(row.cps)\n"
                        try file!.write(contentsOf: Data(line.utf8))
                        try file!.synchronize()
                        DispatchQueue.main.async {
                            self.samples.append(row); self.sampleCount = row.id
                            if self.samples.count > 3000 { self.samples.removeFirst(self.samples.count - 3000) }
                        }
                    }
                }
            } catch { failure = error.localizedDescription }
            if c8855_stop(counter) != 0 {
                failure += (failure.isEmpty ? "" : " / ") + "停止確認に失敗：" + String(cString: c8855_error(counter))
            }
            c8855_close(counter)
            try? file?.close()
            let finalFailure = failure
            DispatchQueue.main.async {
                self.error = finalFailure
                self.status = finalFailure.isEmpty ? "測定終了" : "測定を中止しました"
                self.running = false
                if finalFailure.isEmpty && self.restartRequested { self.start() }
                else { self.restartRequested = false }
            }
        }
    }

    func openDataFolder() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("C8855Counter/measurements")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch { self.error = error.localizedDescription }
    }

    func export() {
        guard !running, let url = savedURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = url.lastPathComponent
        if panel.runModal() == .OK, let destination = panel.url {
            do {
                let data = try Data(contentsOf: url)
                try data.write(to: destination, options: .atomic)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CounterView: View {
    @ObservedObject var model: CounterModel
    private var unit: String { model.rateDisplay ? "counts/s" : "counts" }
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
                    .disabled(model.running || model.checking || !model.connected)
                Button(action: model.stop) { Label("停止", systemImage: "stop.fill").frame(width: 64) }
                    .controlSize(.large).disabled(!model.running).keyboardShortcut(".", modifiers: .command)
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 242)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    if !model.error.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.status).font(.callout).bold()
                                Text(model.error).font(.caption).textSelection(.enabled)
                            }
                            Spacer()
                        }.padding(12).background(Color.orange.opacity(0.09)).cornerRadius(6)
                    }
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.rateDisplay ? "毎秒のカウント" : "1回のカウント").font(.callout).foregroundColor(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(model.latest.map { String(format: model.rateDisplay ? "%.1f" : "%.0f", $0.value(rate: model.rateDisplay)) } ?? "—")
                                    .font(.system(size: 54, weight: .medium, design: .monospaced)).monospacedDigit()
                                Text(unit).font(.callout).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 7) {
                            Text(model.running ? model.status : (model.samples.isEmpty ? "測定待ち" : model.status))
                                .font(.callout).foregroundColor(model.running ? .green : .secondary)
                            Text(model.latest.map { "\(String(format: "%g", $0.seconds))秒間に \($0.counts) カウント" } ?? "出力パルスを数えて表示します")
                                .font(.caption).foregroundColor(.secondary)
                            Text("\(model.sampleCount)回取得").font(.caption).monospacedDigit().foregroundColor(.secondary)
                        }
                    }
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
                    Text(model.savedURL == nil ? "測定データはCSVに自動保存" : (model.running ? "CSVに記録中" : "CSVを保存しました"))
                        .font(.callout)
                    Text(model.savedURL?.lastPathComponent ?? "測定を開始すると記録を作成します")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Button("保存フォルダー", action: model.openDataFolder)
                Button("CSVを書き出す…", action: model.export).disabled(model.running || model.samples.isEmpty)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }.frame(minWidth: 980, minHeight: 650)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { model.probe() }
            .sheet(isPresented: $model.showHelp) { helpSheet }
    }

    private var sidebar: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            Text("カウンター").font(.callout).bold().padding(.bottom, 12)
            Text(model.connectionDetail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            Button("接続を確認", action: model.probe).disabled(model.running || model.checking)
            Divider().padding(.vertical, 22)
            Text("測定設定").font(.callout).bold().padding(.bottom, 16)
            Text("1回の計数時間").font(.caption).foregroundColor(.secondary)
            Picker("1回の計数時間", selection: $model.gate) {
                ForEach(model.gates, id: \.self) { Text($0) }
            }.labelsHidden().padding(.top, 6).disabled(model.checking)
            if model.running && model.gate != model.activeGate {
                Button("変更して再開", action: model.applyGate).padding(.top, 8)
                Text("現在の記録を保存して再開します").font(.caption2).foregroundColor(.secondary).padding(.top, 4)
            }
            Text("測定の終了").font(.caption).foregroundColor(.secondary).padding(.top, 18)
            Picker("測定の終了", selection: $model.continuous) {
                Text("手動で停止").tag(true); Text("時間を指定").tag(false)
            }.labelsHidden().padding(.top, 6).disabled(model.running)
            if !model.continuous {
                HStack {
                    TextField("測定時間", text: $model.duration).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("測定時間（秒）")
                    Text("秒").font(.callout).foregroundColor(.secondary)
                }.padding(.top, 8).disabled(model.running)
            }
            Divider().padding(.vertical, 22)
            Text("グラフ設定").font(.callout).bold().padding(.bottom, 16)
            Text("表示する時間").font(.caption).foregroundColor(.secondary)
            Picker("表示する時間", selection: $model.windowSeconds) {
                Text("直近10秒").tag(10.0); Text("直近30秒").tag(30.0); Text("直近60秒").tag(60.0)
            }.labelsHidden().padding(.top, 6)
            Text("表示する値").font(.caption).foregroundColor(.secondary).padding(.top, 16)
            Picker("表示する値", selection: $model.rateDisplay) {
                Text("毎秒のカウント").tag(true); Text("1回のカウント").tag(false)
            }.labelsHidden().padding(.top, 6)
            Toggle("縦軸の上限を自動調整", isOn: $model.automaticScale).toggleStyle(.checkbox).font(.caption).padding(.top, 16)
            if !model.automaticScale {
                HStack {
                    TextField("上限", text: $model.manualMaximum).textFieldStyle(.roundedBorder).accessibilityLabel("縦軸の上限")
                    Text(unit).font(.caption).foregroundColor(.secondary)
                }.padding(.top, 8)
                if !manualValid {
                    Text("0より大きい数を入力してください。現在は自動調整です。")
                        .font(.caption2).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
            }
            Spacer(minLength: 16)
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
            Text("CSVは自動保存します。「保存フォルダー」で確認し、停止後に「CSVを書き出す…」でコピーできます。")
            Divider()
            Text("メーカー非公式 · v0.3.0").font(.caption).foregroundColor(.secondary)
            Text("USB認識・1秒ゲートの0カウント取得・停止は確認済み。非ゼロの精度、短いゲート、長時間測定、Intel実機は未検証です。")
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "C8855-01 カウンター"
        window.contentView = NSHostingView(rootView: CounterView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        let menu = NSMenu(); let item = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
    }
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
