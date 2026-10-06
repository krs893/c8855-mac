import Foundation
import CoreFoundation

struct APIConfig {
    let gate: String
    let continuous: Bool
    let duration: String
    init(_ json: [String: Any]) throws {
        guard Set(json.keys).isSubset(of: ["gate_seconds", "duration_seconds"]) else { throw ConfigError.invalid }
        let gateValue = json["gate_seconds"] ?? 1.0
        guard let gate = gateValue as? NSNumber, CFGetTypeID(gate) != CFBooleanGetTypeID(),
              [0.1, 0.2, 0.5, 1.0].contains(gate.doubleValue) else { throw ConfigError.invalid }
        self.gate = String(format: "%g秒", gate.doubleValue)
        if let duration = json["duration_seconds"] {
            guard let number = duration as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (1...3600).contains(number.doubleValue) else { throw ConfigError.invalid }
            self.continuous = false; self.duration = number.stringValue
        } else { self.continuous = true; self.duration = "10" }
    }
    enum ConfigError: Error { case invalid }
}
