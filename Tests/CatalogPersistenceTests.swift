import Foundation
import Testing
@testable import MoeKit

struct CatalogPersistenceTests {
    @Test("A missing catalog starts empty")
    func missingCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(try CatalogPersistence(directory: root).load().isEmpty)
    }

    @Test("Project metadata round trips without touching its project directory")
    func roundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = CatalogPersistence(directory: root)
        let project = ProjectRecord(name: "Example", path: "/nonexistent/moekit-fixture", kind: .folder, isPinned: true)
        try persistence.save([project])
        #expect(try persistence.load() == [project])
        #expect(!FileManager.default.fileExists(atPath: project.path))
    }

    @Test("Corrupt catalog data is reported, not silently ignored")
    func malformedCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("projects.json")
        try Data("bad json".utf8).write(to: file)
        #expect(throws: DecodingError.self) { try CatalogPersistence(directory: root).load() }
        #expect(try String(contentsOf: file, encoding: .utf8) == "bad json")
    }
}
