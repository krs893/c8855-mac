import Foundation

@main struct MeasurementExportTests {
    static func main() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let csv = folder.appendingPathComponent("source.csv")
        let metadata = folder.appendingPathComponent("source.metadata.json")
        let raw = Data("sample,counts\n1,20\n".utf8)
        try raw.write(to: csv)
        try Data("{\"csv_file\":\"source.csv\",\"session_id\":\"session\",\"gate_seconds\":0.01}".utf8).write(to: metadata)

        let renamed = folder.appendingPathComponent("renamed.csv")
        let hasMetadata = try MeasurementExport.write(csv: csv, metadata: metadata, to: renamed)
        let exportedData = try Data(contentsOf: renamed)
        assert(hasMetadata)
        assert(exportedData == raw)
        let record = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("renamed.metadata.json"))) as! [String: Any]
        assert(record["csv_file"] as? String == "renamed.csv")
        assert(record["session_id"] as? String == "session")
        assert((record["gate_seconds"] as? NSNumber)?.doubleValue == 0.01)

        let legacy = folder.appendingPathComponent("legacy.csv")
        let hasLegacyMetadata = try MeasurementExport.write(csv: csv, metadata: nil, to: legacy)
        assert(!hasLegacyMetadata)
        assert(!files.fileExists(atPath: folder.appendingPathComponent("legacy.metadata.json").path))
        do {
            _ = try MeasurementExport.write(csv: csv, metadata: nil, to: renamed)
            assertionFailure("Stale metadata must prevent replacement")
        } catch MeasurementExport.ExportError.staleMetadata {}

        let blocked = folder.appendingPathComponent("blocked.csv")
        try files.createDirectory(at: folder.appendingPathComponent("blocked.metadata.json"), withIntermediateDirectories: true)
        do {
            _ = try MeasurementExport.write(csv: csv, metadata: metadata, to: blocked)
            assertionFailure("Metadata directory must prevent export")
        } catch MeasurementExport.ExportError.metadataDestination {}
        assert(!files.fileExists(atPath: blocked.path))

        try Data("[]".utf8).write(to: metadata)
        let invalid = folder.appendingPathComponent("invalid.csv")
        do {
            _ = try MeasurementExport.write(csv: csv, metadata: metadata, to: invalid)
            assertionFailure("Invalid metadata must prevent export")
        } catch MeasurementExport.ExportError.invalidMetadata {}
        assert(!files.fileExists(atPath: invalid.path))
        print("Measurement export: 5 cases passed")
    }
}
