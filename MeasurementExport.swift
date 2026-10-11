import Foundation

enum MeasurementExport {
    /// Returns whether an existing metadata record was exported with the CSV.
    static func write(csv: URL, metadata: URL?, to destination: URL) throws -> Bool {
        let data = try Data(contentsOf: csv)
        let sidecar = destination.deletingPathExtension().appendingPathExtension("metadata.json")
        var metadataData: Data?
        if let metadata = metadata {
            guard var record = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any] else {
                throw ExportError.invalidMetadata
            }
            record["csv_file"] = destination.lastPathComponent
            metadataData = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: sidecar.path, isDirectory: &directory), directory.boolValue {
                throw ExportError.metadataDestination
            }
        } else if FileManager.default.fileExists(atPath: sidecar.path) {
            // A previous sidecar would incorrectly describe this metadata-free CSV.
            throw ExportError.staleMetadata
        }
        try data.write(to: destination, options: .atomic)
        if let metadataData = metadataData {
            do { try metadataData.write(to: sidecar, options: .atomic) }
            catch { throw ExportError.partial(error.localizedDescription) }
        }
        return metadataData != nil
    }

    enum ExportError: LocalizedError {
        case invalidMetadata, metadataDestination, staleMetadata, partial(String)
        var errorDescription: String? {
            switch self {
            case .invalidMetadata: return "測定情報がJSONオブジェクトではありません。書き出しを中止しました。"
            case .metadataDestination: return "測定情報の保存先がフォルダーです。別のCSV名を選んでください。"
            case .staleMetadata: return "保存先に別の測定情報があります。このCSVの測定情報は未記録です。別のCSV名を選んでください。"
            case .partial(let detail): return "CSVは書き出しましたが、測定情報の保存に失敗しました：" + detail
            }
        }
    }
}
