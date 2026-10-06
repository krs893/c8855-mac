import Foundation

struct Sample: Identifiable {
    let id: Int
    let received: String
    let seconds: Double
    let counts: UInt32
    var receivedUnixSeconds: Double? = nil
    var receivedMonotonicSeconds: Double? = nil
    var cps: Double { Double(counts) / seconds }
    var elapsed: Double { Double(id) * seconds }
    func value(rate: Bool) -> Double { rate ? cps : Double(counts) }
}

enum PlotData {
    static func visible(_ rows: [Sample], window: Double) -> [Sample] {
        guard let end = rows.last?.elapsed else { return [] }
        let start = max(0, end - window)
        return rows.filter { $0.elapsed >= start }
    }
    static func maximum(_ rows: [Sample], rate: Bool, automatic: Bool, manual: String) -> Double {
        if !automatic, let value = Double(manual), value.isFinite, value > 0 { return value }
        return max(1, (rows.map { $0.value(rate: rate) }.max() ?? 0) * 1.1)
    }
    static func normalized(_ value: Double, maximum: Double) -> Double {
        min(1, max(0, value / maximum))
    }
}
