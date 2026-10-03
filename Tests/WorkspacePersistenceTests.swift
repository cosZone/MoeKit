import Foundation
import Testing
@testable import MoeKit

@MainActor
struct WorkspacePersistenceTests {
    @Test("Unreadable catalogs stay intact across temporary imports, pins and Demo toggles")
    func corruptCatalogProtection() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("projects.json")
        let original = Data("[{\"unfinished\":".utf8)
        try original.write(to: file)
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        #expect(store.projects.isEmpty)
        #expect(store.errorMessage != nil)
        importProject(into: store, path: root.appendingPathComponent("synthetic-project").path)
        let id = try #require(store.projects.first?.id)
        store.togglePin(id)
        #expect(store.projects.first?.isPinned == true)
        store.isDemoEnabled = true
        store.togglePin(id)
        store.togglePin(DemoData.projects[0].id)
        store.importDiscoveredProjects()
        store.isDemoEnabled = false
        #expect(store.projects.count == 1)
        #expect(store.projects.first?.isPinned == true)
        #expect(try Data(contentsOf: file) == original)
        #expect(store.errorMessage != nil)
    }

    @Test("Refresh and Demo preserve saved project identity, custom names, pins and history")
    func pinsAcrossRefreshAndDemo() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = CatalogPersistence(directory: root)
        let project = ProjectRecord(name: "My custom name", path: root.appendingPathComponent("synthetic-project").path,
            kind: .repository, branch: "old", lastOpened: Date(timeIntervalSince1970: 50), isPinned: true)
        try persistence.save([project])
        let store = WorkspaceStore(isDemoEnabled: false, persistence: persistence)
        importProject(into: store, path: project.path)
        let refreshed = try #require(store.projects.first)
        #expect(refreshed.id == project.id)
        #expect(refreshed.name == project.name)
        #expect(refreshed.lastOpened == project.lastOpened)
        #expect(refreshed.isPinned)
        #expect(refreshed.branch == "fresh")
        let saved = try Data(contentsOf: root.appendingPathComponent("projects.json"))
        for _ in 0..<3 {
            store.isDemoEnabled = true
            store.togglePin(project.id)
            store.togglePin(DemoData.projects[0].id)
            importProject(into: store, path: root.appendingPathComponent("demo-only-attempt").path)
            store.isDemoEnabled = false
        }
        #expect(store.projects == [refreshed])
        #expect(try Data(contentsOf: root.appendingPathComponent("projects.json")) == saved)
        let reopened = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        #expect(reopened.projects == [refreshed])
        #expect(reopened.errorMessage == nil)
    }

    @Test("A save failure reports temporary changes and a later save recovers")
    func failedWriteRecovery() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(name: "Example", path: root.appendingPathComponent("synthetic-project").path, kind: .folder)
        try CatalogPersistence(directory: root).save([project])
        let file = root.appendingPathComponent("projects.json")
        let original = try Data(contentsOf: file)
        var fails = true
        let persistence = CatalogPersistence(directory: root) { data, url in
            if fails { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) }
            try data.write(to: url, options: .atomic)
        }
        let store = WorkspaceStore(isDemoEnabled: false, persistence: persistence)
        store.togglePin(project.id)
        #expect(store.projects.first?.isPinned == true)
        #expect(store.errorMessage != nil)
        #expect(try Data(contentsOf: file) == original)
        fails = false
        importProject(into: store, path: project.path)
        #expect(try CatalogPersistence(directory: root).load().first?.isPinned == true)
        #expect(try CatalogPersistence(directory: root).load().first?.branch == "fresh")
    }

    @Test("Another catalog writer is preserved and the current window reports a conflict")
    func externalWriterConflict() throws {
        let root = fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ProjectRecord(name: "First", path: root.appendingPathComponent("first").path, kind: .folder)
        try CatalogPersistence(directory: root).save([first])
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        let other = ProjectRecord(name: "Other", path: root.appendingPathComponent("other").path, kind: .folder, isPinned: true)
        try CatalogPersistence(directory: root).save([first, other])
        let file = root.appendingPathComponent("projects.json")
        let externalBytes = try Data(contentsOf: file)
        store.togglePin(first.id)
        #expect(store.errorMessage != nil)
        #expect(try Data(contentsOf: file) == externalBytes)
        #expect(try CatalogPersistence(directory: root).load() == [first, other])
    }

    private func fixtureRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-workspace-persistence-\(UUID().uuidString)")
    }

    private func importProject(into store: WorkspaceStore, path: String) {
        let item = DiscoveredRepository(url: URL(fileURLWithPath: path), name: "discovered-name",
                                        kind: .gitRepository, branch: "fresh")
        store.pendingDiscovery = RepositoryScanResult(items: [item], issues: [], visitedDirectories: 0, wasLimited: false)
        store.importSelection = [item.id]
        store.importDiscoveredProjects()
    }
}
