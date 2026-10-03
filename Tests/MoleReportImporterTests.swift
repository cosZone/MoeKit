import Foundation
import Testing
@testable import MoeKit

struct MoleReportImporterTests {
    @Test("Imports a regular report without reading reported paths")
    func regularReport() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"path":"/nonexistent/example","overview":false,"entries":[],"total_size":0}"#.utf8).write(to: file)
        let report = try await MoleReportImporter().load(file)
        #expect(report.path == "/nonexistent/example")
        #expect(report.coverage == .unknown)
    }

    @Test("Directories are rejected before opening")
    func directoryRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: MoleReportImporter.ImportError.self) { try await MoleReportImporter().load(root) }
    }

    @Test("Oversized reports are rejected before decoding")
    func oversizedReport() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0x20, count: MoleReportImporter.maximumBytes + 1).write(to: file)
        await #expect(throws: MoleReportImporter.ImportError.self) { try await MoleReportImporter().load(file) }
    }
}
