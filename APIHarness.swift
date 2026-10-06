// Test-only process: actual app model and API, injected mock USB and temp data folder.
import Foundation

@main struct APIHarness {
    static func main() {
        let args = CommandLine.arguments
        let model = CounterModel(usbLibrary: args[1], dataFolder: URL(fileURLWithPath: args[2]), apiPort: UInt16(args[3])!)
        model.startAPI()
        model.probe()
        RunLoop.main.run()
        withExtendedLifetime(model) {}
    }
}
