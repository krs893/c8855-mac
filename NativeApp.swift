import Cocoa
import SwiftUI
import UniformTypeIdentifiers

final class CounterModel: ObservableObject {
    @Published var gate = "0.1秒"
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
        guard let duration = Double(duration), duration.isFinite, duration >= 1, duration <= 3600 else {
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
                DispatchQueue.main.async { self.error = message; self.status = "測定を開始できません。"; self.running = false; self.restartRequested = false }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "waveform.path").font(.largeTitle).foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("C8855-01 カウンター").font(.title2).bold()
                    Text("Mac用試作版 · USB通信確認済み、カウント精度は検証前").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button("接続を確認", action: model.probe).disabled(model.running || model.checking)
                VStack(alignment: .leading) {
                    Text("1回の計数時間").font(.caption)
                    Picker("1回の計数時間", selection: $model.gate) {
                        ForEach(model.gates, id: \.self) { Text($0) }
                    }.labelsHidden().frame(width: 110)
                }.disabled(model.checking)
                if model.running {
                    Button("計数時間を適用", action: model.applyGate).disabled(model.gate == model.activeGate)
                }
                Button("測定開始", action: model.start).buttonStyle(.borderedProminent).disabled(model.running || model.checking)
                Button("停止", action: model.stop).disabled(!model.running)
            }
            HStack(spacing: 16) {
                Toggle("連続測定（停止するまで）", isOn: $model.continuous).disabled(model.running).toggleStyle(.checkbox)
                if !model.continuous {
                    Text("測定時間")
                    TextField("秒数", text: $model.duration).textFieldStyle(.roundedBorder).frame(width: 70).disabled(model.running)
                    Text("秒")
                }
                Spacer()
                if model.running { Text("計数時間：\(model.activeGate)").font(.caption).foregroundColor(.secondary) }
            }
            Text(model.status).font(.callout)
            if !model.error.isEmpty { Text(model.error).foregroundColor(.red).font(.callout).textSelection(.enabled) }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(model.latest.map { String(format: model.rateDisplay ? "%.1f" : "%.0f", $0.value(rate: model.rateDisplay)) } ?? "—").font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(model.rateDisplay ? "counts / second" : "counts / gate").foregroundColor(.secondary)
                Spacer()
            }
            Text(model.latest.map { "\(String(format: "%g", $0.seconds))秒間に \($0.counts) カウント · \(model.sampleCount)回取得" } ?? "まだ測定していません。")
                .font(.callout).foregroundColor(.secondary)
            HStack(spacing: 16) {
                Picker("横軸", selection: $model.windowSeconds) {
                    Text("直近10秒").tag(10.0); Text("直近30秒").tag(30.0); Text("直近60秒").tag(60.0)
                }.frame(width: 160)
                Picker("縦軸", selection: $model.rateDisplay) {
                    Text("毎秒のカウント").tag(true); Text("1回のカウント").tag(false)
                }.frame(width: 190)
                Toggle("自動範囲", isOn: $model.automaticScale).toggleStyle(.checkbox)
                if !model.automaticScale {
                    TextField("縦軸の上限", text: $model.manualMaximum).textFieldStyle(.roundedBorder).frame(width: 90)
                }
                Spacer()
                Toggle("グラフを止める", isOn: $model.freeze).toggleStyle(.checkbox).onChange(of: model.freeze) { _ in model.freezeChanged() }
            }.font(.callout)
            GeometryReader { geo in
                let rows = model.plotRows
                let maxValue = PlotData.maximum(rows, rate: model.rateDisplay, automatic: model.automaticScale, manual: model.manualMaximum)
                let end = rows.last?.elapsed ?? 0
                let start = max(0, end - model.windowSeconds)
                let span = max(model.windowSeconds, end - start)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
                    Path { p in
                        for i in 0...5 {
                            let x = 50 + Double(i) / 5 * (geo.size.width - 70)
                            p.move(to: CGPoint(x: x, y: 28)); p.addLine(to: CGPoint(x: x, y: geo.size.height - 32))
                            let y = 28 + Double(i) / 5 * (geo.size.height - 60)
                            p.move(to: CGPoint(x: 50, y: y)); p.addLine(to: CGPoint(x: geo.size.width - 20, y: y))
                        }
                    }.stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    Path { p in
                        for (i, row) in rows.enumerated() {
                            let x = 50 + (row.elapsed - start) / span * (geo.size.width - 70)
                            let y = geo.size.height - 32 - PlotData.normalized(row.value(rate: model.rateDisplay), maximum: maxValue) * (geo.size.height - 60)
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }.stroke(Color.accentColor, lineWidth: 2)
                    VStack(alignment: .leading) {
                        Text("\(String(format: "%g", maxValue)) \(model.rateDisplay ? "cps" : "counts")")
                        Spacer()
                        HStack { Text("\(String(format: "%g", start)) s"); Spacer(); Text("\(String(format: "%g", start + span)) s") }
                    }.font(.caption).foregroundColor(.secondary).padding(10)
                }
            }.frame(minHeight: 120)
            HStack {
                Button("CSVを書き出す…", action: model.export).disabled(model.running || model.samples.isEmpty)
                if let url = model.savedURL {
                    Button("保存先を開く") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Spacer()
            }
            Text(model.freeze ? "グラフの表示だけ停止しています。計数とCSV記録は続きます。" : "横軸は計数時間の累積です。計数時間の変更時は記録を分けて再開します。")
                .font(.caption).foregroundColor(.secondary)
            Text("SPADの±5 V電源は別途必要です。カウンターのDC OUTはSPADに使わないでください。")
                .font(.caption).foregroundColor(.secondary)
        }.padding(28).frame(minWidth: 900, minHeight: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CounterModel()
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 760),
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
