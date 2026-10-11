// Test-only process: actual app model and API, injected mock USB and temp data folder.
import Foundation

@main struct APIHarness {
    static func main() {
        let args = CommandLine.arguments
        let model = CounterModel(usbLibrary: args[1], dataFolder: URL(fileURLWithPath: args[2]), apiPort: UInt16(args[3])!)
        model.startAPI()
        let normalRequest = model.api.handle!
        // Only this headless test harness exposes UI-equivalent condition edits.
        model.api.handle = { method, path, payload in
            guard method == "POST", path == "/api/test/ui" else { return normalRequest(method, path, payload) }
            if let gate = payload["gate"] as? String { model.gate = gate }
            if let duration = payload["duration"] as? String { model.duration = duration }
            if let continuous = payload["continuous"] as? Bool { model.continuous = continuous }
            switch payload["action"] as? String {
            case "apply_gate": model.applyGate()
            case "start": model.start()
            default: break
            }
            if let gate = payload["after_gate"] as? String { model.gate = gate }
            return (200, model.apiStatus())
        }
        model.probe()
        RunLoop.main.run()
        withExtendedLifetime(model) {}
    }
}
