import Foundation

/// Imports data only. It never reads any filesystem path contained in a report.
actor MoleReportImporter {
    static let maximumBytes = 16 * 1024 * 1024

    func load(_ url: URL) async throws -> MoleAnalyzeReport {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ImportError.notRegularFile
        }
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Self.maximumBytes else {
            throw ImportError.tooLarge
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw ImportError.tooLarge }
        try Task.checkCancellation()
        let report = try JSONDecoder().decode(MoleAnalyzeReport.self, from: data)
        try Task.checkCancellation()
        return report
    }

    enum ImportError: LocalizedError {
        case notRegularFile, tooLarge
        var errorDescription: String? {
            switch self {
            case .notRegularFile: String(localized: "Choose a regular JSON report file, not a folder or symbolic link.")
            case .tooLarge: String(localized: "Report exceeds the 16 MB import limit.")
            }
        }
    }
}
