import Foundation
import Network

/// Local HTTP API. No UI assets, remote binding, USB access, or browser requests.
final class LocalAPI {
    typealias Reply = (Int, [String: Any])
    var handle: ((String, String, [String: Any]) -> Reply)?
    var initialState: (() -> [String: Any])?
    var availability: ((Bool, String) -> Void)?
    private let queue = DispatchQueue(label: "c8855.api")
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var timer: DispatchSourceTimer?
    let port: UInt16
    private final class Peer {
        let connection: NWConnection
        var input = Data()
        var streaming = false
        var pending = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }
    init(port: UInt16 = 8855) { self.port = port }
    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready: DispatchQueue.main.async { self.availability?(true, "127.0.0.1:\(self.port)") }
                case .failed(let error):
                    DispatchQueue.main.async { self.availability?(false, error.localizedDescription) }
                    self.closeAll()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.sendEvent(["type": "heartbeat"]) }
            timer.resume(); self.timer = timer
        } catch { availability?(false, error.localizedDescription) }
    }
    func stop() { queue.async { self.closeAll() } }
    private func closeAll() {
        timer?.cancel(); timer = nil
        listener?.cancel(); listener = nil
        for peer in peers.values { peer.connection.cancel() }
        peers.removeAll()
    }
    func broadcast(_ event: [String: Any]) { queue.async { self.sendEvent(event) } }
    private func sendEvent(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        let line = data + Data([10])
        for (id, peer) in peers where peer.streaming { send(line, id: id) }
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < 16 else { connection.cancel(); return }
        let id = UUID(); peers[id] = Peer(connection)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.drop(id) }
            if case .cancelled = state { self?.peers.removeValue(forKey: id) }
        }
        connection.start(queue: queue)
        receive(id)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, let peer = self.peers[id], !peer.streaming else { return }
            self.drop(id)
        }
    }
    private func drop(_ id: UUID) { peers.removeValue(forKey: id)?.connection.cancel() }
    private func send(_ data: Data, id: UUID, close: Bool = false) {
        guard let peer = peers[id], peer.pending + data.count <= 65536 else { drop(id); return }
        peer.pending += data.count
        peer.connection.send(content: data, completion: .contentProcessed { [weak self, weak peer] error in
            peer?.pending -= data.count
            if close || error != nil { self?.drop(id) }
        })
    }
    private func receive(_ id: UUID) {
        guard let peer = peers[id] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self = self, let peer = self.peers[id] else { return }
            if peer.streaming {
                if complete || error != nil || data != nil { self.drop(id) }
                else { self.receive(id) }
                return
            }
            if let data = data { peer.input.append(data) }
            if peer.input.count > 20480 { self.respond(id, 413, ["error": "Request too large"]); return }
            if self.process(id) { return }
            if complete || error != nil { self.drop(id) } else { self.receive(id) }
        }
    }
    private func process(_ id: UUID) -> Bool {
        guard let peer = peers[id], let range = peer.input.range(of: Data("\r\n\r\n".utf8)) else { return false }
        guard range.lowerBound <= 16384,
              let header = String(data: peer.input[..<range.lowerBound], encoding: .utf8) else {
            respond(id, 400, ["error": "Invalid headers"]); return true
        }
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ").map(String.init)
        guard request.count == 3 else { respond(id, 400, ["error": "Invalid request"]); return true }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { respond(id, 400, ["error": "Invalid header"]); return true }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { respond(id, 400, ["error": "Duplicate header"]); return true }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["origin"] == nil, headers["transfer-encoding"] == nil,
              ["127.0.0.1:\(port)", "localhost:\(port)"].contains(headers["host"]?.lowercased() ?? "") else {
            respond(id, 403, ["error": "Only local non-browser clients are allowed"]); return true
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= 4096 else { respond(id, 413, ["error": "Invalid body length"]); return true }
        guard peer.input.count >= range.upperBound + length else { return false }
        let method = request[0], path = request[1]
        guard method == "GET" || method == "POST" else { respond(id, 405, ["error": "Use GET or POST"]); return true }
        var payload: [String: Any] = [:]
        if method == "POST" {
            guard headers["content-type"]?.lowercased().split(separator: ";").first == "application/json",
                  let json = try? JSONSerialization.jsonObject(with: peer.input[range.upperBound..<range.upperBound + length]),
                  let object = json as? [String: Any] else {
                respond(id, 400, ["error": "POST requires a JSON object"]); return true
            }
            payload = object
        }
        if method == "GET" && path == "/api/stream" {
            // Register and snapshot on the main queue: no gap between initial status and new samples.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let state = self.initialState?() ?? [:]
                self.queue.async {
                    guard let peer = self.peers[id] else { return }
                    peer.streaming = true
                    self.send(Data("HTTP/1.0 200 OK\r\nContent-Type: application/x-ndjson\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8), id: id)
                    if let data = try? JSONSerialization.data(withJSONObject: state.merging(["type": "status"], uniquingKeysWith: { _, new in new })) {
                        self.send(data + Data([10]), id: id)
                    }
                    self.receive(id)
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let reply = self.handle?(method, path, payload) ?? (503, ["error": "API unavailable"])
                self.queue.async { self.respond(id, reply.0, reply.1) }
            }
        }
        return true
    }
    private func respond(_ id: UUID, _ status: Int, _ object: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let header = "HTTP/1.0 \(status) Response\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        send(Data(header.utf8) + body, id: id, close: true)
    }
}
