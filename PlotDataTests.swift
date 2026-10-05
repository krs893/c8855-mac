import Foundation

@main struct PlotTests {
    static func main() {
        let rows = (1...100).map { Sample(id: $0, received: "", seconds: 0.1, counts: UInt32($0)) }
        assert(rows.last!.elapsed == 10)
        assert(rows.last!.cps == 1000)
        assert(rows.last!.value(rate: false) == 100)
        let visible = PlotData.visible(rows, window: 3)
        assert(abs(visible.first!.elapsed - 7) < 0.000001)
        assert(visible.last!.elapsed == 10)
        assert(PlotData.maximum(rows, rate: true, automatic: true, manual: "1") == 1100)
        assert(PlotData.maximum(rows, rate: false, automatic: false, manual: "50") == 50)
        for input in ["nan", "inf", "-2", "0", "text"] {
            assert(PlotData.maximum([], rate: true, automatic: false, manual: input) == 1)
        }
        assert(PlotData.normalized(2000, maximum: 1000) == 1)
        assert(PlotData.normalized(250, maximum: 1000) == 0.25)
        assert(PlotData.visible([], window: 30).isEmpty)
        print("Plot data tests passed")
    }
}
