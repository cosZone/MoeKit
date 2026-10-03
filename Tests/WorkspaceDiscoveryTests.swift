import Foundation
import Testing
@testable import MoeKit

@MainActor
struct WorkspaceDiscoveryTests {
    private func fixture() throws -> (URL, WorkspaceStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-workspace-test-\(UUID().uuidString)")
        let git = root.appendingPathComponent("project/.git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        return (root, WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root.appendingPathComponent("catalog"))))
    }

    private func waitForDiscovery(_ store: WorkspaceStore) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        while store.isScanning && Date.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.isScanning)
    }

    @Test("Repeated start is coalesced and discovery waits for explicit import")
    func repeatedStart() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.startDiscovery(roots: [root], scanChildren: true)
        store.startDiscovery(roots: [root], scanChildren: true)
        try await waitForDiscovery(store)
        #expect(store.tasks.count == 1)
        #expect(store.projects.isEmpty)
        #expect(store.pendingDiscovery?.items.count == 1)
        store.importDiscoveredProjects()
        #expect(store.projects.count == 1)
        #expect(store.pendingDiscovery == nil)
    }

    @Test("Immediate cancellation never creates an import result")
    func cancellation() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.startDiscovery(roots: [root], scanChildren: true)
        store.cancelScan()
        try await waitForDiscovery(store)
        #expect(store.pendingDiscovery == nil)
        #expect(store.projects.isEmpty)
        #expect(store.tasks.first?.status == .cancelled)
        #expect(store.scanProgress == nil)
    }

    @Test("Crossing Demo boundaries discards an obsolete discovery")
    func demoBoundary() async throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        store.startDiscovery(roots: [root], scanChildren: true)
        store.isDemoEnabled = true
        store.isDemoEnabled = false
        try await waitForDiscovery(store)
        #expect(store.pendingDiscovery == nil)
        #expect(store.projects.isEmpty)
        #expect(store.importSelection.isEmpty)
        #expect(store.tasks.first?.status == .cancelled)
    }

    @Test("Pinned worktrees stay visible below collapsed unpinned parents")
    func filteredChildrenRemainVisible() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        let parent = ProjectRecord(name: "main", path: "/fixture/main", kind: .repository)
        let child = ProjectRecord(name: "work", path: "/fixture/work", kind: .worktree, isPinned: true, parentID: parent.id)
        store.projects = [parent, child]
        store.expandedProjectIDs = []
        store.projectFilter = .pinned
        #expect(store.projectRows(sortedBy: [KeyPathComparator(\ProjectRecord.name)]).map(\.id) == [parent.id, child.id])
        store.projectFilter = .all
        store.projectSearch = "work"
        #expect(store.projectRows(sortedBy: [KeyPathComparator(\ProjectRecord.name)]).map(\.id) == [parent.id, child.id])
    }

    @Test("A real cleanup review is cleared across Demo changes")
    func cleanupReviewModeBoundary() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        let project = ProjectRecord(name: "work", path: "/fixture/private-work", kind: .worktree)
        store.projects = [project]
        store.selectedProjectID = project.id
        store.presentCleanupReview()
        #expect(store.cleanupReviewProject?.id == project.id)
        store.isDemoEnabled = true
        #expect(store.cleanupReviewProject == nil)
        #expect(store.cleanupReviewProjectID == nil)
        store.presentCleanupReview()
        #expect(store.cleanupReviewProject == nil)
        store.isDemoEnabled = false
        #expect(store.cleanupReviewProject == nil)
        #expect(store.cleanupReviewProjectID == nil)
    }

}
