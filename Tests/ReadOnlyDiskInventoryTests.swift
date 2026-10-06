import Darwin
import Foundation
import Testing
@testable import MoeKit

/// Metadata reads and changes below are restricted to newly created UUID-owned
/// fixtures. Never enumerate or clean the real user's Caches or Trash.
@Suite("Read-only metadata sizing", .serialized)
struct ReadOnlyDiskInventoryTests {
    private func fixture() throws -> URL {
        let root = try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)
            .appendingPathComponent("MoeKit-ReadOnly-Size-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func folder(_ parent: URL, _ name: String) throws -> URL {
        let value = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return value
    }
    @Test("Sizes include readable file metadata without opening file contents or following links")
    func metadataOnly() throws {
        let root = try fixture(), tree = try folder(root, "cache"), outside = try folder(root, "outside")
        let privateFile = tree.appendingPathComponent("no-content-access")
        try Data(repeating: 7, count: 79).write(to: privateFile, options: .withoutOverwriting)
        try #require(chmod(privateFile.path, 0o000) == 0)
        defer { _ = chmod(privateFile.path, 0o600) }
        try Data(repeating: 8, count: 1_234).write(to: outside.appendingPathComponent("sentinel"), options: .withoutOverwriting)
        try #require(symlink(outside.path, tree.appendingPathComponent("outside-link").path) == 0)
        try #require(symlink(tree.path, tree.appendingPathComponent("loop").path) == 0)
        let estimate = try ReadOnlyDiskInventory.estimate(parent: AnchoredDirectory.selected(root), name: "cache", budget: .init())
        #expect(estimate.isComplete && estimate.logicalBytes == 79)
        #expect(estimate.visitedEntries == 4)
        #expect(try Data(contentsOf: outside.appendingPathComponent("sentinel")) == Data(repeating: 8, count: 1_234))
    }
    @Test("A partially denied subtree keeps known bytes and the exact denied path", arguments: [EACCES, EPERM])
    func partialPermission(_ code: Int32) throws {
        let root = try fixture(), tree = try folder(root, "cache")
        try Data(repeating: 1, count: 123).write(to: tree.appendingPathComponent("readable"), options: .withoutOverwriting)
        let denied = try folder(tree, "denied")
        try Data(repeating: 1, count: 456).write(to: denied.appendingPathComponent("unseen"), options: .withoutOverwriting)
        let estimate = try ReadOnlyDiskInventory.estimate(parent: AnchoredDirectory.selected(root), name: "cache", budget: .init()) { url in
            if url == denied { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        }
        #expect(!estimate.isComplete && estimate.logicalBytes == 123)
        #expect(estimate.issues.contains { $0.contains(denied.path) })
        #expect(estimate.formattedSize != ByteCountFormatter.string(fromByteCount: 123, countStyle: .file))
    }
    @Test("Unknown, partial zero, and a verified empty directory remain distinct")
    func unknownIsNotZero() throws {
        let root = try fixture(), empty = try folder(root, "empty")
        let parent = try AnchoredDirectory.selected(root)
        let complete = try ReadOnlyDiskInventory.estimate(parent: parent, name: empty.lastPathComponent, budget: .init())
        #expect(complete.isComplete && complete.logicalBytes == 0)
        let denied = try ReadOnlyDiskInventory.estimate(parent: parent, name: empty.lastPathComponent, budget: .init()) { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        #expect(!denied.isComplete && denied.logicalBytes == nil)
        let limited = try ReadOnlyDiskInventory.estimate(parent: parent, name: empty.lastPathComponent,
            budget: .init(.init(totalEntries: 0)))
        #expect(!limited.isComplete && limited.logicalBytes == nil)
    }
    @Test("An item entry cap retains partial bytes and does not consume the next item's budget")
    func fairBudgets() throws {
        let root = try fixture(), large = try folder(root, "large"), small = try folder(root, "small")
        for index in 0..<8 { try Data(repeating: 1, count: 10).write(to: large.appendingPathComponent("f\(index)"), options: .withoutOverwriting) }
        try Data(repeating: 1, count: 71).write(to: small.appendingPathComponent("readable"), options: .withoutOverwriting)
        let parent = try AnchoredDirectory.selected(root), budget = ReadOnlyDiskInventory.Budget(.init(totalEntries: 100, entriesPerItem: 3))
        let partial = try ReadOnlyDiskInventory.estimate(parent: parent, name: "large", budget: budget)
        let complete = try ReadOnlyDiskInventory.estimate(parent: parent, name: "small", budget: budget)
        #expect(!partial.isComplete && partial.logicalBytes == 20)
        #expect(complete.isComplete && complete.logicalBytes == 71)
        #expect(budget.remaining == 95)
    }
    @Test("A top-level listing cap preserves rows and marks the listing incomplete")
    func partialListing() throws {
        let root = try fixture()
        for name in ["one", "two", "three"] { _ = try folder(root, name) }
        let listing = try ReadOnlyDiskInventory.list(AnchoredDirectory.selected(root), limit: 2)
        #expect(listing.names.count == 2 && !listing.isComplete && listing.issue != nil)
    }
    @Test("Cancellation cannot be converted into a successful partial report")
    func cancellation() throws {
        let root = try fixture(); _ = try folder(root, "cache")
        #expect(throws: CancellationError.self) {
            try ReadOnlyDiskInventory.estimate(parent: AnchoredDirectory.selected(root), name: "cache", budget: .init()) { _ in
                throw CancellationError()
            }
        }
    }
}
