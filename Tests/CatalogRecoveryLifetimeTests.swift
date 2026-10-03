import Foundation
import Testing
@testable import MoeKit

/// Exercise fixture construction and the production rejection path without
/// assertion-expression macros. Run optimized and under Address Sanitizer so
/// invalid-record fixtures reach the catalog instead of failing during encoding.
struct CatalogRecoveryLifetimeTests {
    private enum Failure: Error {
        case fixtureChanged, loadSucceeded, wrongLoadError, saveSucceeded, wrongSaveError, originalChanged
    }

    @Test("Repeated catalog rejection preserves exact errors and bytes without assertion closures")
    func rejectedCatalogLifetime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-catalog-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects.json")
        for _ in 0..<16 {
            for variant in 0..<8 {
                let first = ProjectRecord(name: "Original", path: root.appendingPathComponent("not-created-project").path,
                                          kind: .folder, lastOpened: Date(timeIntervalSince1970: 50), isPinned: true)
                var second = ProjectRecord(id: variant == 0 ? first.id : UUID(), name: "Second",
                                           path: first.path + "-second", kind: .folder)
                switch variant {
                case 0: break
                case 1: second.path = first.path + "/child/.."
                case 2: second.path = "relative/project"
                case 3: second.parentID = UUID()
                case 4: second.parentID = second.id
                case 5: second.demoChangeCount = 0
                case 6: second.demoUnavailable = true
                default: second.kind = .group
                }
                let original = try JSONEncoder().encode([first, second])
                let decoded = try JSONDecoder().decode([ProjectRecord].self, from: original)
                guard decoded == [first, second] else { throw Failure.fixtureChanged }
                try original.write(to: file)
                let persistence = CatalogPersistence(directory: root)
                do {
                    _ = try persistence.load()
                    throw Failure.loadSucceeded
                } catch let error as CatalogPersistence.CatalogError {
                    guard error == .invalidRecords else { throw Failure.wrongLoadError }
                }
                do {
                    try persistence.save([first])
                    throw Failure.saveSucceeded
                } catch let error as CatalogPersistence.CatalogError {
                    guard error == .recoveryRequired else { throw Failure.wrongSaveError }
                }
                let persisted = try Data(contentsOf: file)
                guard persisted == original else { throw Failure.originalChanged }
            }
        }
    }
}
