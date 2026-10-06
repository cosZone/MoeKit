import Darwin
import Foundation
import Testing
@testable import MoeKit

/// Only uniquely created, marker-owned fixture trees. No test reads or mutates
/// the real ~/.Trash. Fixtures and interrupted records are intentionally retained.
private struct TrashFixture: Sendable {
    let base: URL, trash: URL, recovery: URL, sentinel: URL
    let marker: Data
    init() throws {
        base = try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)
            .appendingPathComponent("MoeKit-Trash-Owned-\(UUID())")
        trash = base.appendingPathComponent("Trash")
        recovery = base.appendingPathComponent("Support/MoeKit/TrashRemovalRecords")
        sentinel = base.appendingPathComponent("outside-sentinel")
        marker = Data("MoeKit owned Trash fixture \(UUID())".utf8)
        for url in [base, trash, base.appendingPathComponent("Support")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try marker.write(to: sentinel, options: .withoutOverwriting)
        try marker.write(to: base.appendingPathComponent("owner-marker"), options: .withoutOverwriting)
    }
    var environment: TrashEnvironment { .init(home: base, trash: trash, recovery: recovery, enforceProductionPolicy: false) }
    func executor(_ checkpoint: @escaping @Sendable (CleanupCheckpoint) throws -> Void = { _ in }) -> NativeTrashExecutor {
        .init(environment: environment, checkpoint: checkpoint)
    }
    func file(_ name: String) throws -> URL {
        let url = trash.appendingPathComponent(name)
        try marker.write(to: url, options: .withoutOverwriting)
        return url
    }
    func folder(_ name: String) throws -> URL {
        let url = trash.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try marker.write(to: url.appendingPathComponent("owned.bin"), options: .withoutOverwriting)
        return url
    }
    func plan(_ executor: NativeTrashExecutor, paths: [URL], action: TrashRemovalPlan.Action = .selectedItems,
              context: TrashContext) async throws -> TrashRemovalPlan {
        let report = try await executor.inspect(context: context)
        return try await executor.prepare(inspectionID: report.id, selectedPaths: Set(paths.map(\.path)), action: action, context: context)
    }
    func verifySentinel() throws {
        #expect(try Data(contentsOf: sentinel) == marker)
        #expect(try Data(contentsOf: base.appendingPathComponent("owner-marker")) == marker)
    }
}

@Suite("Exact-snapshot native Trash", .serialized)
struct TrashExecutorTests {
    private var context: TrashContext { .init(generation: UUID()) }
    @Test("Read-only scan and prepare create no records; file dates are modification dates")
    func readOnlyInventory() async throws {
        let f = try TrashFixture(), file = try f.file("item 空格\n.txt"), folder = try f.folder("folder"), scope = context
        let executor = f.executor(), report = try await executor.inspect(context: scope)
        #expect(report.items.count == 2 && report.items.allSatisfy(\.isEligible))
        #expect(report.items.allSatisfy { $0.modifiedAt != nil })
        #expect(report.items.first(where: { $0.url == file })?.logicalBytes == Int64(f.marker.count))
        #expect(report.items.first(where: { $0.url.path == folder.path })?.manifest?.entries.count == 2)
        _ = try await executor.prepare(inspectionID: report.id, selectedPaths: [file.path], action: .selectedItems, context: scope)
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        try f.verifySentinel()
    }
    @Test("An empty or missing fixture Trash stays read-only")
    func emptyTrash() async throws {
        let f = try TrashFixture(), scope = context
        let empty = try await f.executor().inspect(context: scope)
        #expect(empty.rootExists && empty.items.isEmpty && !empty.canClearSnapshot)
        let renamed = f.base.appendingPathComponent("kept-empty-trash")
        try FileManager.default.moveItem(at: f.trash, to: renamed)
        let missing = try await f.executor().inspect(context: scope)
        #expect(!missing.rootExists && missing.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.trash.path))
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
    }
    @Test("Selected file, nonempty tree, root link and internal hard links remove only the reviewed entries")
    func supportedItems() async throws {
        let f = try TrashFixture(), file = try f.file("file"), folder = try f.folder("tree"), neighbor = try f.file("unselected"), scope = context
        let rootLink = f.trash.appendingPathComponent("root-link")
        try #require(symlink(f.sentinel.path, rootLink.path) == 0)
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try #require(symlink(f.base.path, nested.appendingPathComponent("outside-link").path) == 0)
        try #require(link(folder.appendingPathComponent("owned.bin").path, nested.appendingPathComponent("hard-link").path) == 0)
        let externalLink = f.base.appendingPathComponent("external-hardlink")
        try #require(link(file.path, externalLink.path) == 0)
        let executor = f.executor(), plan = try await f.plan(executor, paths: [file, folder, rootLink], context: scope)
        let result = try await executor.remove(planID: plan.id, context: scope, progress: { _ in })
        #expect(result.items.count == 3 && result.items.allSatisfy { $0.status == .deleted })
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try Data(contentsOf: externalLink) == f.marker)
        #expect(try Data(contentsOf: neighbor) == f.marker)
        let records = try await executor.readRecords()
        #expect(records.count == 3 && records.allSatisfy { $0.record?.state == .deleted })
        try f.verifySentinel()
    }
    @Test("Both clear and selected plans are one-use; discard prevents deletion")
    func oneUseAndDiscard() async throws {
        let f = try TrashFixture(), a = try f.file("a"), scope = context
        let executor = f.executor(), old = try await f.plan(executor, paths: [a], context: scope)
        await executor.discardPlan()
        await #expect(throws: (any Error).self) { try await executor.remove(planID: old.id, context: scope, progress: { _ in }) }
        let plan = try await f.plan(executor, paths: [a], action: .clearSnapshot, context: scope)
        let result = try await executor.remove(planID: plan.id, context: scope, progress: { _ in })
        #expect(result.items.first?.status == .deleted)
        await #expect(throws: (any Error).self) { try await executor.remove(planID: plan.id, context: scope, progress: { _ in }) }
    }
    @Test("Clear refuses an omitted item and any newly arrived root item before confirmation")
    func clearSnapshotMembership() async throws {
        let f = try TrashFixture(), a = try f.file("a"), b = try f.file("b"), scope = context
        let executor = f.executor(), report = try await executor.inspect(context: scope)
        await #expect(throws: (any Error).self) {
            try await executor.prepare(inspectionID: report.id, selectedPaths: [a.path], action: .clearSnapshot, context: scope)
        }
        let plan = try await f.plan(executor, paths: [a, b], action: .clearSnapshot, context: scope)
        let later = try f.file("later")
        await #expect(throws: (any Error).self) { try await executor.remove(planID: plan.id, context: scope, progress: { _ in }) }
        #expect(try Data(contentsOf: a) == f.marker)
        #expect(try Data(contentsOf: later) == f.marker)
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
    }
    @Test("Later root arrivals are never silently added to a selected deletion")
    func selectedLeavesNewFiles() async throws {
        let f = try TrashFixture(), a = try f.file("a"), scope = context
        let executor = f.executor(), plan = try await f.plan(executor, paths: [a], context: scope)
        let later = try f.file("later")
        let result = try await executor.remove(planID: plan.id, context: scope, progress: { _ in })
        #expect(result.items.first?.status == .deleted)
        #expect(try Data(contentsOf: later) == f.marker)
    }
    @Test("A late clear arrival after capture remains untouched and the result covers only the snapshot")
    func clearLateArrival() async throws {
        let f = try TrashFixture(), a = try f.file("a"), scope = context
        let executor = f.executor { point in if case .afterCapture = point { _ = try f.file("late-arrival") } }
        let plan = try await f.plan(executor, paths: [a], action: .clearSnapshot, context: scope)
        let result = try await executor.remove(planID: plan.id, context: scope, progress: { _ in })
        #expect(result.items.count == 1 && result.items.first?.status == .deleted)
        #expect(try Data(contentsOf: f.trash.appendingPathComponent("late-arrival")) == f.marker)
    }
    @Test("A changed descendant refuses the batch before records are written")
    func changedDescendant() async throws {
        let f = try TrashFixture(), folder = try f.folder("tree"), scope = context
        let executor = f.executor(), plan = try await f.plan(executor, paths: [folder], context: scope)
        try f.marker.write(to: folder.appendingPathComponent("new"), options: .withoutOverwriting)
        await #expect(throws: (any Error).self) { try await executor.remove(planID: plan.id, context: scope, progress: { _ in }) }
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        #expect(try Data(contentsOf: folder.appendingPathComponent("new")) == f.marker)
    }
    @Test("Root replacement, renamed home Trash, and symlink Trash never authorize replacement contents")
    func namespaceReplacement() async throws {
        let f = try TrashFixture(), a = try f.file("a"), scope = context
        let executor = f.executor(), plan = try await f.plan(executor, paths: [a], context: scope)
        let kept = f.base.appendingPathComponent("kept-trash")
        try FileManager.default.moveItem(at: f.trash, to: kept)
        try #require(symlink(kept.path, f.trash.path) == 0)
        await #expect(throws: (any Error).self) { try await executor.remove(planID: plan.id, context: scope, progress: { _ in }) }
        await #expect(throws: (any Error).self) { try await f.executor().inspect(context: scope) }
        #expect(try Data(contentsOf: kept.appendingPathComponent("a")) == f.marker)
        try f.verifySentinel()
    }
    @Test("Root leaf substitution is captured but never destroyed")
    func substitutedRootLeaf() async throws {
        let f = try TrashFixture(), a = try f.file("a"), scope = context
        let replacement = Data("unconfirmed replacement".utf8)
        let executor = f.executor { point in
            if case .beforeLeafCapture = point {
                let records = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil)
                let operation = try #require(records.first { UUID(uuidString: $0.lastPathComponent) != nil })
                try FileManager.default.moveItem(at: operation.appendingPathComponent("payload"), to: operation.appendingPathComponent("preserved-original"))
                try replacement.write(to: operation.appendingPathComponent("payload"), options: .withoutOverwriting)
            }
        }
        let plan = try await f.plan(executor, paths: [a], context: scope)
        let result = try await executor.remove(planID: plan.id, context: scope, progress: { _ in })
        let row = try #require(result.items.first), operation = try #require(row.operationURL)
        #expect(row.status == .retained)
        #expect(try Data(contentsOf: operation.appendingPathComponent("preserved-original")) == f.marker)
        #expect(try Data(contentsOf: operation.appendingPathComponent("delete-entry-000000")) == replacement)
        try f.verifySentinel()
    }
    @Test("Descendant substitution is retained in the exact private capture slot")
    func substitutedDescendant() async throws {
        let f = try TrashFixture(), tree = try f.folder("tree"), scope = context
        let replacement = Data("changed descendant".utf8)
        let executor = f.executor { point in
            if case .beforeLeafCapture = point {
                let operations = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil)
                let operation = try #require(operations.first { UUID(uuidString: $0.lastPathComponent) != nil })
                let original = operation.appendingPathComponent("payload/owned.bin")
                try FileManager.default.moveItem(at: original, to: operation.appendingPathComponent("preserved-original"))
                try replacement.write(to: original, options: .withoutOverwriting)
            }
        }
        let plan = try await f.plan(executor, paths: [tree], context: scope)
        let result = try await executor.remove(planID: plan.id, context: scope, progress: { _ in })
        let row = try #require(result.items.first), operation = try #require(row.operationURL)
        #expect(row.status == .retained)
        #expect(try Data(contentsOf: operation.appendingPathComponent("delete-entry-000001")) == replacement)
        #expect(try Data(contentsOf: operation.appendingPathComponent("preserved-original")) == f.marker)
        try f.verifySentinel()
    }
    @Test("Namespace replacement during deletion stops before destroying a captured leaf")
    func lateRootReplacement() async throws {
        let f = try TrashFixture(), a = try f.file("a"), scope = context
        let executor = f.executor { point in
            if case .beforeLeafCapture = point {
                try FileManager.default.moveItem(at: f.trash, to: f.base.appendingPathComponent("kept-trash"))
                try FileManager.default.createDirectory(at: f.trash, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                _ = try f.file("replacement-item")
            }
        }
        let plan = try await f.plan(executor, paths: [a], context: scope)
        let result = try await executor.remove(planID: plan.id, context: scope, progress: { _ in })
        let row = try #require(result.items.first), operation = try #require(row.operationURL)
        #expect(row.status == .retained)
        #expect(try Data(contentsOf: operation.appendingPathComponent("payload")) == f.marker)
        #expect(try Data(contentsOf: f.trash.appendingPathComponent("replacement-item")) == f.marker)
    }
    @Test("Cancellation retains captured data, stops later items, and a fresh scan does not retry private slots")
    func cancellationAndRetry() async throws {
        let f = try TrashFixture(), a = try f.file("a"), b = try f.file("b"), scope = context
        let executor = f.executor { point in if case .beforePermanentDelete = point { throw CancellationError() } }
        let plan = try await f.plan(executor, paths: [a, b], context: scope)
        let result = try await executor.remove(planID: plan.id, context: scope, progress: { _ in })
        #expect(result.items.map(\.status) == [.retained, .notAttempted])
        let operation = try #require(result.items.first?.operationURL)
        #expect(try Data(contentsOf: operation.appendingPathComponent("payload")) == f.marker)
        let fresh = f.executor(), next = try await fresh.inspect(context: scope)
        #expect(next.items.map(\.url) == [b])
        await #expect(throws: (any Error).self) { try await fresh.remove(planID: plan.id, context: scope, progress: { _ in }) }
        let remainingPlan = try await fresh.prepare(inspectionID: next.id, selectedPaths: [b.path], action: .selectedItems, context: scope)
        let remaining = try await fresh.remove(planID: remainingPlan.id, context: scope, progress: { _ in })
        #expect(remaining.items.first?.status == .deleted)
        #expect(try Data(contentsOf: operation.appendingPathComponent("payload")) == f.marker)
    }
    @Test("Partial batch results preserve earlier success and never treat later failure as success")
    func partialBatch() async throws {
        let f = try TrashFixture(), a = try f.file("a"), b = try f.file("b"), scope = context
        let executor = f.executor { point in
            if case .afterPermanentDelete = point {
                try Data("new bytes".utf8).write(to: b)
            }
        }
        let plan = try await f.plan(executor, paths: [a, b], context: scope)
        let result = try await executor.remove(planID: plan.id, context: scope, progress: { _ in })
        #expect(result.items.map(\.status) == [.deleted, .notAttempted])
        #expect(try Data(contentsOf: b) == Data("new bytes".utf8))
    }
    @Test("Private records remain readable after a new executor and incomplete records cannot authorize retries")
    func incompleteRecord() async throws {
        let f = try TrashFixture(), a = try f.file("a"), scope = context
        let executor = f.executor(), plan = try await f.plan(executor, paths: [a], context: scope)
        let result = try await executor.remove(planID: plan.id, context: scope, progress: { _ in })
        let operation = try #require(result.items.first?.operationURL)
        try Data("{".utf8).write(to: operation.appendingPathComponent("000004.trash.json"), options: .withoutOverwriting)
        let records = try await f.executor().readRecords()
        #expect(records.count == 1 && records.first?.record == nil && records.first?.issue != nil)
        try f.verifySentinel()
    }
    @Test("A capped top-level listing retains readable selected items but cannot clear the whole snapshot")
    func cappedListing() async throws {
        let f = try TrashFixture(), executor = f.executor(), scope = context
        for index in 0...NativeTrashExecutor.maximumItems { _ = try f.file("item-\(index)") }
        let report = try await executor.inspect(context: scope)
        #expect(report.items.count == NativeTrashExecutor.maximumItems)
        #expect(!report.listingIsComplete && !report.canClearSnapshot && !report.issues.isEmpty)
        let first = try #require(report.items.first)
        #expect(first.logicalBytes == Int64(f.marker.count) && first.isEligible)
        let selected = try await executor.prepare(inspectionID: report.id, selectedPaths: [first.id], action: .selectedItems, context: scope)
        #expect(selected.items.count == 1)
        await #expect(throws: (any Error).self) {
            try await executor.prepare(inspectionID: report.id, selectedPaths: Set(report.items.map(\.id)), action: .clearSnapshot, context: scope)
        }
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        try f.verifySentinel()
    }
    @Test("Vaults, credential descendants, Git metadata and nonprivate roots remain visible but not deletable")
    func protectedContent() async throws {
        let f = try TrashFixture(), vault = try f.file("personal.vault"), tree = try f.folder("with-secret"), git = try f.folder("repository"), scope = context
        try f.marker.write(to: tree.appendingPathComponent(".env"), options: .withoutOverwriting)
        try FileManager.default.createDirectory(at: git.appendingPathComponent(".git"), withIntermediateDirectories: false)
        let executor = f.executor(), report = try await executor.inspect(context: scope)
        #expect(report.items.count == 3 && report.items.allSatisfy { !$0.isEligible && $0.blocker != nil })
        #expect(!report.canClearSnapshot)
        await #expect(throws: (any Error).self) {
            try await executor.prepare(inspectionID: report.id, selectedPaths: [vault.path], action: .selectedItems, context: scope)
        }
        try #require(chmod(f.trash.path, 0o755) == 0)
        let readable = try await f.executor().inspect(context: scope)
        #expect(readable.items.allSatisfy { !$0.isEligible })
        #expect(readable.items.first(where: { $0.url == vault })?.logicalBytes == Int64(f.marker.count))
    }
    @Test("Symlink ancestors and production scope injection are refused without inspecting real Trash")
    func productionScopeGuard() async throws {
        let f = try TrashFixture(), scope = context
        let production = TrashEnvironment(home: f.base, trash: f.trash, recovery: f.recovery, enforceProductionPolicy: true)
        await #expect(throws: (any Error).self) { try await NativeTrashExecutor(environment: production).inspect(context: scope) }
        let external = TrashEnvironment(home: f.base, trash: f.base.deletingLastPathComponent().appendingPathComponent("unowned-trash"), recovery: f.recovery, enforceProductionPolicy: false)
        await #expect(throws: (any Error).self) { try await NativeTrashExecutor(environment: external).inspect(context: scope) }
        try f.verifySentinel()
    }
    @Test("A mutation-granting ACL blocks a leaf even when POSIX modes look private")
    func mutationACL() async throws {
        let f = try TrashFixture(), file = try f.file("with-acl"), scope = context
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0); defer { close(fd) }
        let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::allow:write\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try #require(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0)
        let report = try await f.executor().inspect(context: scope)
        #expect(report.items.count == 1 && report.items.first?.isEligible == false)
        #expect(report.items.first?.logicalBytes == Int64(f.marker.count))
        #expect(try Data(contentsOf: file) == f.marker)
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
    }
    @Test("A FIFO remains unsupported without opening its contents")
    func unsupportedTypes() async throws {
        let f = try TrashFixture(), scope = context
        let fifo = f.trash.appendingPathComponent("pipe")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let report = try await f.executor().inspect(context: scope)
        #expect(report.items.count == 1 && report.items.first?.isEligible == false)
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
    }
    @Test("Mismatched workspace generation and unknown selected path cannot authorize deletion")
    func contextAndPathGuards() async throws {
        let f = try TrashFixture(), a = try f.file("a"), scope = context
        let executor = f.executor(), report = try await executor.inspect(context: scope)
        await #expect(throws: (any Error).self) {
            try await executor.prepare(inspectionID: report.id, selectedPaths: [f.sentinel.path], action: .selectedItems, context: scope)
        }
        let plan = try await f.plan(executor, paths: [a], context: scope)
        await #expect(throws: (any Error).self) { try await executor.remove(planID: plan.id, context: context, progress: { _ in }) }
        #expect(try Data(contentsOf: a) == f.marker)
    }
}
