import Cocoa
import SwiftUI
import UniformTypeIdentifiers

final class CounterModel: ObservableObject {
    @Published var apiReady = false
    @Published var apiDetail = "準備中"
    let api: LocalAPI
    private let suppliedLibrary: String?
    private let suppliedFolder: URL?
    init(usbLibrary: String? = nil, dataFolder: URL? = nil, apiPort: UInt16 = 8855) {
        suppliedLibrary = usbLibrary; suppliedFolder = dataFolder; api = LocalAPI(port: apiPort)
    }
    private var sessionID = ""
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
    private var library: String { suppliedLibrary ?? Bundle.main.resourceURL!.appendingPathComponent("libusb-1.0.dylib").path }
    var latest: Sample? { samples.last }
    var plotRows: [Sample] { PlotData.visible(freeze ? frozenSamples : samples, window: windowSeconds) }
    func startAPI() {
        api.handle = { [weak self] method, path, payload in
            self?.apiRequest(method, path, payload) ?? (503, ["error": "App unavailable"])
        }
        api.initialState = { [weak self] in self?.apiStatus() ?? [:] }
        api.availability = { [weak self] ready, detail in self?.apiReady = ready; self?.apiDetail = detail }
        api.start()
    }
    func apiStatus() -> [String: Any] {
        var result: [String: Any] = ["running": running, "checking": checking, "connected": connected,
            "status": status, "error": error, "sample_count": sampleCount, "session_id": sessionID,
            "selected_gate": gate, "active_gate": activeGate, "csv_file": savedURL?.path ?? "",
            "clock_unix_seconds": Date().timeIntervalSince1970]
        if let row = latest { result["latest"] = sampleEvent(row) }
        return result
    }
    private func emitStatus() { api.broadcast(apiStatus().merging(["type": "status"], uniquingKeysWith: { _, new in new })) }
    private func sampleEvent(_ row: Sample) -> [String: Any] {
        var event: [String: Any] = ["type": "sample", "session_id": sessionID,
            "sample": row.id, "received_at": row.received, "gate_seconds": row.seconds,
            "counts": row.counts, "counts_per_second": row.cps, "elapsed_gate_seconds": row.elapsed]
        if let timestamp = row.receivedUnixSeconds { event["received_unix_seconds"] = timestamp }
        if let timestamp = row.receivedMonotonicSeconds { event["received_monotonic_seconds"] = timestamp }
        return event
    }
    private func apiRequest(_ method: String, _ path: String, _ payload: [String: Any]) -> LocalAPI.Reply {
        if method == "GET" && path == "/api/status" { return (200, apiStatus()) }
        if method == "POST" && path == "/api/probe" {
            guard !running && !checking else { return (409, ["error": "Counter is busy"]) }
            guard payload.isEmpty else { return (400, ["error": "Probe takes an empty object"]) }
            probe(); return (202, apiStatus())
        }
        if method == "POST" && path == "/api/start" {
            guard !running && !checking else { return (409, ["error": "Counter is busy"]) }
            guard connected else { return (409, ["error": "Connect C8855-01 and probe first"]) }
            guard let config = try? APIConfig(payload) else { return (400, ["error": "gate_seconds: 0.1/0.2/0.5/1; duration_seconds: optional 1..3600"]) }
            gate = config.gate; continuous = config.continuous; duration = config.duration
            start(); return (202, apiStatus())
        }
        if method == "POST" && path == "/api/stop" {
            guard payload.isEmpty else { return (400, ["error": "Stop takes an empty object"]) }
            stop(); return (202, apiStatus())
        }
        return (404, ["error": "Unknown endpoint"])
    }
    func freezeChanged() { frozenSamples = freeze ? samples : [] }
    func applyGate() {
        guard running else { return }
        restartRequested = true
        lock.lock(); stopRequested = true; lock.unlock()
        status = "記録を保存し、計数時間を変更しています…"
        emitStatus()
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
                self.emitStatus()
            }
        }
    }

    func stop() {
        restartRequested = false
        lock.lock(); stopRequested = true; lock.unlock()
        if running { status = "停止しています…" }
        emitStatus()
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
        sessionID = UUID().uuidString
        let recordSession = sessionID
        emitStatus()
        lock.lock(); stopRequested = false; lock.unlock()
        let path = library
        let dataFolder = suppliedFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("C8855Counter/measurements")
        queue.async {
            var buffer = [CChar](repeating: 0, count: 512)
            guard let counter = c8855_open(path, &buffer, buffer.count) else {
                let message = String(cString: buffer)
                DispatchQueue.main.async { self.connected = false; self.connectionDetail = "USB接続を確認してください。"; self.error = message; self.status = "測定を開始できません。"; self.running = false; self.restartRequested = false; self.emitStatus() }
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
                try file!.write(contentsOf: Data("received_at,sample,gate_seconds,counts,counts_per_second,received_unix_seconds,received_monotonic_seconds,session_id\n".utf8))
                DispatchQueue.main.async { self.savedURL = url }
                if c8855_start(counter, code, UInt32(seconds * 2000 + 1000)) != 0 {
                    failure = String(cString: c8855_error(counter))
                } else {
                    DispatchQueue.main.async { self.status = "測定中"; self.emitStatus() }
                    let clock = ISO8601DateFormatter(); clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    var i = 0
                    let limit = Int(ceil(duration / seconds))
                    while continuous || i < limit {
                        if self.shouldStop() { break }
                        i += 1
                        var count: UInt32 = 0
                        if c8855_read(counter, &count) != 0 { failure = String(cString: c8855_error(counter)); break }
                        let received = Date()
                        let monotonic = ProcessInfo.processInfo.systemUptime
                        let row = Sample(id: i, received: clock.string(from: received), seconds: seconds, counts: count,
                                         receivedUnixSeconds: received.timeIntervalSince1970, receivedMonotonicSeconds: monotonic)
                        let line = "\(row.received),\(i),\(seconds),\(count),\(row.cps),\(received.timeIntervalSince1970),\(monotonic),\(recordSession)\n"
                        try file!.write(contentsOf: Data(line.utf8))
                        try file!.synchronize()
                        DispatchQueue.main.async {
                            self.samples.append(row); self.sampleCount = row.id
                            if self.samples.count > 3000 { self.samples.removeFirst(self.samples.count - 3000) }
                            self.api.broadcast(self.sampleEvent(row))
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
                self.emitStatus()
                if finalFailure.isEmpty && self.restartRequested { self.start() }
                else { self.restartRequested = false }
            }
        }
    }

    func openDataFolder() {
        let folder = suppliedFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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

