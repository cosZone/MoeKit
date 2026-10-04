import Darwin
import Foundation
import Testing
@testable import MoeKit

private struct InstallerFixtureEvidence: InstallerUseEvidenceProviding {
    let result: InstallerUseEvidence
    func evidence(for target: InstallerUseTarget) async -> InstallerUseEvidence { result }
}

private final class InstallerFixtureSink: InstallerTrashSink, @unchecked Sendable {
    let destination: URL
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    init(_ destination: URL) { self.destination = destination }
    func trash(_ url: URL) throws -> URL {
        lock.withLock { calls += 1 }
        let source = try InstallerDirectoryAnchor.open(url.deletingLastPathComponent())
        let target = try InstallerDirectoryAnchor.open(destination)
        let result = destination.appendingPathComponent(url.lastPathComponent)
        try InstallerFileAccess.exclusiveMove(from: source, name: url.lastPathComponent, to: target, destinationName: result.lastPathComponent)
        return result
    }
}

private struct InstallerFixture: Sendable {
    let base: URL
    let downloads: URL
    let source: URL
    let trash: URL
    let recovery: URL
    let marker: Data
    let sentinel: URL
    init(name: String = "Owned installer 空格\n.dmg", realTrash: Bool = false, hostedHomeFixture: Bool = false) throws {
        if hostedHomeFixture {
            let env = ProcessInfo.processInfo.environment
            try #require(env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted")
        }
        let temp = try MoleAnalysisFiles.canonicalURL(hostedHomeFixture ? FileManager.default.homeDirectoryForCurrentUser : FileManager.default.temporaryDirectory)
        base = temp.appendingPathComponent("MoeKit-Installer-Test-\(UUID().uuidString)")
        downloads = base.appendingPathComponent("Downloads")
        source = downloads.appendingPathComponent(name)
        trash = realTrash ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") : base.appendingPathComponent("Trash")
        recovery = base.appendingPathComponent("Support/MoeKit/InstallerRecovery")
        marker = Data("Uniquely owned MoeKit test fixture \(UUID().uuidString)".utf8)
        sentinel = base.appendingPathComponent("outside-sentinel")
        for url in [base, downloads, base.appendingPathComponent("Support")] + (realTrash ? [] : [trash]) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try marker.write(to: source, options: .withoutOverwriting)
        try Data("outside remains unchanged".utf8).write(to: sentinel, options: .withoutOverwriting)
    }
    var environment: InstallerTrashEnvironment { .init(downloads: downloads, recoveryRoot: recovery, trash: trash, enforceLocalVolume: false, enforceTrustedAncestry: false) }
    var scope: InstallerTrashScope { .init(generation: UUID(), liveAnalysisID: UUID(), liveDirectory: downloads,
        liveEntryPaths: [source.path], protectedPaths: [], catalogIsKnown: true) }
    var context: InstallerRecoveryContext { .init(generation: UUID(), protectedPaths: [], catalogIsKnown: true) }
    func executor(sink: (any InstallerTrashSink)? = nil, evidence: InstallerUseEvidence = .noUseObserved,
                  hook: @escaping @Sendable (InstallerMutationCheckpoint) throws -> Void = { _ in }) -> NativeInstallerTrashExecutor {
        NativeInstallerTrashExecutor(environment: environment, evidence: InstallerFixtureEvidence(result: evidence),
            sink: sink ?? InstallerFixtureSink(trash), nativeExecutionEnabled: true, checkpoint: hook)
    }
    func checkSentinel() throws { #expect(try Data(contentsOf: sentinel) == Data("outside remains unchanged".utf8)) }
    // No recursive cleanup: crash/retention tests intentionally leave their tiny
    // owned fixtures intact for inspection and the ephemeral CI runner lifecycle.
}

@Suite("Confirmed installer capture and recovery", .serialized)
struct InstallerTrashExecutorTests {
    @Test("Preview and cancellation never create recovery storage")
    func readOnlyPlan() async throws {
        let f = try InstallerFixture(), executor = f.executor()
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        #expect(plan.file.bytes == f.marker.count)
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        await executor.discardPlans()
        await #expect(throws: InstallerTrashFailure.expired) { try await executor.moveToTrash(planID: plan.id, scope: plan.scope) }
        #expect(try Data(contentsOf: f.source) == f.marker)
        try f.checkSentinel()
    }
    @Test("Write-granting source/Downloads ACLs refuse before preparation or confirmation", arguments: ["source", "downloads"])
    func writeGrantingACLs(_ target: String) async throws {
        let f = try InstallerFixture(), executor = f.executor()
        let parent = try InstallerDirectoryAnchor.open(f.downloads)
        let file = try InstallerFileDescriptor(parent: parent, name: f.source.lastPathComponent)
        let descriptor = target == "source" ? file.fd : parent.fd
        let safe = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::deny:delete\n"))
        defer { acl_free(UnsafeMutableRawPointer(safe)) }
        try #require(acl_set_fd_np(descriptor, safe, ACL_TYPE_EXTENDED) == 0)
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let rights = target == "source" ? "write" : "delete_child"
        let unsafe = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::allow:\(rights)\n"))
        defer { acl_free(UnsafeMutableRawPointer(unsafe)) }
        try #require(acl_set_fd_np(descriptor, unsafe, ACL_TYPE_EXTENDED) == 0)
        await #expect(throws: (any Error).self) { try await executor.moveToTrash(planID: plan.id, scope: plan.scope) }
        await #expect(throws: InstallerTrashFailure.unsupported) { try await executor.prepare(selection: f.source, scope: f.scope) }
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        #expect(try Data(contentsOf: f.source) == f.marker)
        try f.checkSentinel()
    }
    @Test("Exact one-use plan moves and separately confirms original-path restore")
    func happyPath() async throws {
        let f = try InstallerFixture(), executor = f.executor()
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let moved = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        #expect(moved.movedToTrash)
        let receipt = try #require(moved.receipt)
        #expect(receipt.state == .trashed)
        #expect(try Data(contentsOf: #require(receipt.trashURL)) == f.marker)
        await #expect(throws: InstallerTrashFailure.expired) { try await executor.moveToTrash(planID: plan.id, scope: plan.scope) }
        let context = f.context
        let restore = try await executor.prepareRestore(receiptID: receipt.id, context: context)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
        let result = try await executor.restore(planID: restore.id, context: context)
        #expect(result.receipt?.state == .restored)
        #expect(try Data(contentsOf: f.source) == f.marker)
        #expect(try await executor.recoveryReceipts().count == 1)
        try f.checkSentinel()
    }
    @Test("Unknown or observed descriptor use blocks unchanged before storage", arguments: [InstallerUseEvidence.unavailable(reason: "denied"), .observedUse(reason: "open")])
    func useBlocks(_ evidence: InstallerUseEvidence) async throws {
        let f = try InstallerFixture(), executor = f.executor(evidence: evidence)
        await #expect(throws: (any Error).self) { try await executor.prepare(selection: f.source, scope: f.scope) }
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        #expect(try Data(contentsOf: f.source) == f.marker)
    }
    @Test("Imported, other-root, unknown-catalog and protected scopes cannot prepare")
    func scopeGuards() async throws {
        let f = try InstallerFixture(), executor = f.executor()
        for scope in [
            InstallerTrashScope(generation: UUID(), liveAnalysisID: UUID(), liveDirectory: f.downloads, liveEntryPaths: [], protectedPaths: [], catalogIsKnown: true),
            .init(generation: UUID(), liveAnalysisID: UUID(), liveDirectory: f.base, liveEntryPaths: [f.source.path], protectedPaths: [], catalogIsKnown: true),
            .init(generation: UUID(), liveAnalysisID: UUID(), liveDirectory: f.downloads, liveEntryPaths: [f.source.path], protectedPaths: [], catalogIsKnown: false),
            .init(generation: UUID(), liveAnalysisID: UUID(), liveDirectory: f.downloads, liveEntryPaths: [f.source.path], protectedPaths: [f.downloads.path], catalogIsKnown: true)
        ] { await #expect(throws: (any Error).self) { try await executor.prepare(selection: f.source, scope: scope) } }
        try f.checkSentinel()
    }
    @Test("Hardlinks, symlink leaves and flat packages are unsupported")
    func unsupportedKinds() async throws {
        let f = try InstallerFixture(name: "owned.pkg")
        await #expect(throws: InstallerTrashFailure.unsupported) { try await f.executor().prepare(selection: f.source, scope: f.scope) }
        let g = try InstallerFixture()
        try #require(link(g.source.path, g.base.appendingPathComponent("second-link").path) == 0)
        await #expect(throws: InstallerTrashFailure.unsupported) { try await g.executor().prepare(selection: g.source, scope: g.scope) }
    }
    @Test("Replacement immediately before capture never reaches Trash", arguments: ["file", "symlink", "directory"])
    func captureReplacement(_ kind: String) async throws {
        let f = try InstallerFixture(), sink = InstallerFixtureSink(f.trash)
        let saved = f.base.appendingPathComponent("retained-original.dmg")
        let executor = f.executor(sink: sink) { point in
            guard point == .beforeCapture else { return }
            try FileManager.default.moveItem(at: f.source, to: saved)
            switch kind {
            case "file": try Data("unconfirmed replacement".utf8).write(to: f.source, options: .withoutOverwriting)
            case "symlink": try FileManager.default.createSymbolicLink(at: f.source, withDestinationURL: f.sentinel)
            default: try FileManager.default.createDirectory(at: f.source, withIntermediateDirectories: false)
            }
        }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let result = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        #expect(!result.movedToTrash); #expect(sink.callCount == 0)
        #expect(result.receipt?.state == .rolledBack)
        #expect(try Data(contentsOf: saved) == f.marker)
        if kind == "file" { #expect(try Data(contentsOf: f.source) == Data("unconfirmed replacement".utf8)) }
        if kind == "symlink" { #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.source.path) == f.sentinel.path) }
        try f.checkSentinel()
    }
    @Test("Rollback collision retains both captured and new source objects")
    func rollbackCollision() async throws {
        let f = try InstallerFixture(), sink = InstallerFixtureSink(f.trash)
        let executor = f.executor(sink: sink) { point in
            if point == .afterCapture {
                try Data("new neighbor at original name".utf8).write(to: f.source, options: .withoutOverwriting)
                throw InstallerTrashFailure.cancelled
            }
        }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let result = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        #expect(sink.callCount == 0); #expect(result.requiresRecovery)
        #expect(try Data(contentsOf: f.source) == Data("new neighbor at original name".utf8))
        #expect(try Data(contentsOf: plan.recoveryURL.appendingPathComponent(f.source.lastPathComponent)) == f.marker)
        try f.checkSentinel()
    }
    @Test("Post-Trash interruption stays uncertain without automatic retry")
    func postTrashUnknown() async throws {
        let f = try InstallerFixture(), sink = InstallerFixtureSink(f.trash)
        let executor = f.executor(sink: sink) { point in if point == .afterTrash { throw InstallerTrashFailure.journal } }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let result = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        #expect(result.receipt?.state == .uncertain); #expect(!result.movedToTrash)
        #expect(sink.callCount == 1)
        let items = try await executor.recoveryReceipts()
        #expect(items.first?.receipt?.state == .uncertain)
        await #expect(throws: (any Error).self) { try await executor.prepareRestore(receiptID: plan.id, context: f.context) }
        #expect(try Data(contentsOf: f.trash.appendingPathComponent(f.source.lastPathComponent)) == f.marker)
    }
    @Test("Restore collision and fresh project protection never overwrite")
    func restoreGuards() async throws {
        let f = try InstallerFixture(), executor = f.executor()
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        _ = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        let protected = InstallerRecoveryContext(generation: UUID(), protectedPaths: [f.downloads.path], catalogIsKnown: true)
        await #expect(throws: InstallerTrashFailure.protected) { try await executor.prepareRestore(receiptID: plan.id, context: protected) }
        try Data("collision".utf8).write(to: f.source, options: .withoutOverwriting)
        await #expect(throws: InstallerTrashFailure.collision) { try await executor.prepareRestore(receiptID: plan.id, context: f.context) }
        #expect(try Data(contentsOf: f.source) == Data("collision".utf8))
        try f.checkSentinel()
    }
    @Test("Torn journal after capture retains payload without rollback mutation")
    func journalFailureAfterCapture() async throws {
        let f = try InstallerFixture(), sink = InstallerFixtureSink(f.trash)
        let executor = f.executor(sink: sink) { point in
            if point == .afterCapture {
                let directories = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil)
                let operation = try #require(directories.first(where: { UUID(uuidString: $0.lastPathComponent) != nil }))
                try Data("{".utf8).write(to: operation.appendingPathComponent("000001.json"), options: .withoutOverwriting)
            }
        }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let result = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        #expect(!result.movedToTrash); #expect(result.requiresRecovery); #expect(sink.callCount == 0)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
        #expect(try Data(contentsOf: plan.recoveryURL.appendingPathComponent(f.source.lastPathComponent)) == f.marker)
        let items = try await executor.recoveryReceipts()
        #expect(items.first?.receipt == nil); #expect(items.first?.issue != nil)
        #expect(!FileManager.default.fileExists(atPath: plan.recoveryURL.appendingPathComponent("000002.json").path))
    }
    @Test("Renamed Downloads parent after capture prevents rollback into a replacement")
    func sourceParentReplacement() async throws {
        let f = try InstallerFixture(), sink = InstallerFixtureSink(f.trash)
        let executor = f.executor(sink: sink) { point in
            if point == .afterCapture {
                try FileManager.default.moveItem(at: f.downloads, to: f.base.appendingPathComponent("old-Downloads"))
                try FileManager.default.createDirectory(at: f.downloads, withIntermediateDirectories: false)
                try Data("replacement sentinel".utf8).write(to: f.source)
                throw InstallerTrashFailure.changed
            }
        }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let result = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        #expect(result.requiresRecovery); #expect(sink.callCount == 0)
        #expect(try Data(contentsOf: f.source) == Data("replacement sentinel".utf8))
        #expect(try Data(contentsOf: plan.recoveryURL.appendingPathComponent(f.source.lastPathComponent)) == f.marker)
        try f.checkSentinel()
    }
    @Test("Restore source replacement is captured, detected and returned without reaching Downloads")
    func restoreReplacement() async throws {
        let f = try InstallerFixture(), sink = InstallerFixtureSink(f.trash)
        let saved = f.base.appendingPathComponent("approved-original.dmg")
        let executor = f.executor(sink: sink) { point in
            if point == .beforeRestoreCapture {
                let trashFile = f.trash.appendingPathComponent(f.source.lastPathComponent)
                try FileManager.default.moveItem(at: trashFile, to: saved)
                try Data("unconfirmed restore replacement".utf8).write(to: trashFile, options: .withoutOverwriting)
            }
        }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        _ = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        let context = f.context
        let restore = try await executor.prepareRestore(receiptID: plan.id, context: context)
        let result = try await executor.restore(planID: restore.id, context: context)
        #expect(result.requiresRecovery)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
        #expect(try Data(contentsOf: saved) == f.marker)
        #expect(try Data(contentsOf: f.trash.appendingPathComponent(f.source.lastPathComponent)) == Data("unconfirmed restore replacement".utf8))
        try f.checkSentinel()
    }
    @Test("A destination created after restore confirmation is never overwritten")
    func lateRestoreCollision() async throws {
        let f = try InstallerFixture(), executor = f.executor { point in
            if point == .beforeRestore { try Data("new original-path content".utf8).write(to: f.source, options: .withoutOverwriting) }
        }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        _ = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        let context = f.context
        let restore = try await executor.prepareRestore(receiptID: plan.id, context: context)
        let result = try await executor.restore(planID: restore.id, context: context)
        #expect(result.requiresRecovery); #expect(result.receipt?.state == .retained)
        #expect(try Data(contentsOf: f.source) == Data("new original-path content".utf8))
        #expect(try Data(contentsOf: plan.recoveryURL.appendingPathComponent("restore.dmg")) == f.marker)
        try f.checkSentinel()
    }
    @Test("Same-size Trash rewrite with restored mtime is rejected by exact receipt ctime")
    func changedTrashBytesPreservedMtime() async throws {
        let f = try InstallerFixture(), executor = f.executor()
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let result = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        let receipt = try #require(result.receipt), target = try #require(receipt.trashURL)
        let expected = try #require(receipt.trashFile)
        let fd = open(target.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(try InstallerFileAccess.snapshot(fd) == expected)
        try #require(try Data(contentsOf: target) == f.marker)
        usleep(20_000)
        var changed = f.marker; changed[0] ^= 1
        let written = changed.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        try #require(written == changed.count)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                     timespec(tv_sec: Int(expected.modifiedSeconds), tv_nsec: Int(expected.modifiedNanoseconds))]
        try #require(futimens(fd, &times) == 0)
        let actual = try InstallerFileAccess.snapshot(fd)
        #expect(actual.modifiedSeconds == expected.modifiedSeconds)
        #expect(actual.modifiedNanoseconds == expected.modifiedNanoseconds)
        #expect(actual != expected)
        await #expect(throws: InstallerTrashFailure.changed) { try await executor.prepareRestore(receiptID: receipt.id, context: f.context) }
        #expect(try Data(contentsOf: target) == changed)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
    }
    @Test("A failure after rollback never falsely reports the original bytes in staging")
    func rollbackReceiptFailure() async throws {
        let f = try InstallerFixture(), sink = InstallerFixtureSink(f.trash)
        let executor = f.executor(sink: sink) { point in
            if point == .beforeTrash { throw InstallerTrashFailure.cancelled }
            if point == .afterRollback { throw InstallerTrashFailure.journal }
        }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let result = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        #expect(result.receipt?.state == .uncertain); #expect(sink.callCount == 0)
        #expect(try Data(contentsOf: f.source) == f.marker)
        #expect(!FileManager.default.fileExists(atPath: plan.recoveryURL.appendingPathComponent(f.source.lastPathComponent).path))
    }
    @Test("Substituted operation directory never redirects Trash or rollback")
    func replacedStagingDirectory() async throws {
        let f = try InstallerFixture(), sink = InstallerFixtureSink(f.trash)
        let saved = f.base.appendingPathComponent("original-owned-operation")
        let executor = f.executor(sink: sink) { point in
            if point == .afterCapture {
                let names = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil)
                let operation = try #require(names.first(where: { UUID(uuidString: $0.lastPathComponent) != nil }))
                try FileManager.default.moveItem(at: operation, to: saved)
                try FileManager.default.createDirectory(at: operation, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Data("replacement stage sentinel".utf8).write(to: operation.appendingPathComponent(f.source.lastPathComponent))
            }
        }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let result = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        #expect(result.requiresRecovery); #expect(sink.callCount == 0)
        #expect(try Data(contentsOf: saved.appendingPathComponent(f.source.lastPathComponent)) == f.marker)
        #expect(try Data(contentsOf: plan.recoveryURL.appendingPathComponent(f.source.lastPathComponent)) == Data("replacement stage sentinel".utf8))
        try f.checkSentinel()
    }
    @Test("Another instance changing the saved catalog invalidates confirmation")
    func externalCatalogChange() async throws {
        let f = try InstallerFixture(), sink = InstallerFixtureSink(f.trash), executor = f.executor(sink: sink)
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let catalog = CatalogPersistence(directory: f.recovery.deletingLastPathComponent())
        _ = try catalog.load(); try catalog.save([])
        await #expect(throws: InstallerTrashFailure.changed) { try await executor.moveToTrash(planID: plan.id, scope: plan.scope) }
        #expect(sink.callCount == 0); #expect(try Data(contentsOf: f.source) == f.marker)
    }
    @Test("Saved catalog writer cannot replace protection during native capture")
    func catalogLockedDuringCapture() async throws {
        let f = try InstallerFixture(), sink = InstallerFixtureSink(f.trash)
        let executor = f.executor(sink: sink) { point in
            if point == .beforeCapture {
                #expect(throws: CatalogPersistence.CatalogError.writerBusy) {
                    try CatalogWriteCoordinator.withExclusiveAccess(at: f.recovery.deletingLastPathComponent()) { _ in
                        Issue.record("A catalog writer unexpectedly entered during a native file operation")
                    }
                }
            }
        }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let result = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        #expect(result.movedToTrash); #expect(sink.callCount == 1)
    }
    @Test("Changed disk catalog also invalidates an already confirmed restore plan")
    func externalCatalogChangeBeforeRestore() async throws {
        let f = try InstallerFixture(), executor = f.executor()
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let moved = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        let destination = try #require(moved.receipt?.trashURL)
        let context = f.context
        let restore = try await executor.prepareRestore(receiptID: plan.id, context: context)
        let catalog = CatalogPersistence(directory: f.recovery.deletingLastPathComponent())
        _ = try catalog.load(); try catalog.save([])
        await #expect(throws: InstallerTrashFailure.changed) { try await executor.restore(planID: restore.id, context: context) }
        #expect(try Data(contentsOf: destination) == f.marker)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
    }
    @Test("A staging replacement detected before Trash is never rolled into Downloads")
    func stageReplacementBeforeRollback() async throws {
        let f = try InstallerFixture(), sink = InstallerFixtureSink(f.trash)
        let executor = f.executor(sink: sink) { point in
            if point == .beforeTrash {
                let names = try FileManager.default.contentsOfDirectory(at: f.recovery, includingPropertiesForKeys: nil)
                let op = try #require(names.first(where: { UUID(uuidString: $0.lastPathComponent) != nil }))
                let source = op.appendingPathComponent(f.source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: op.appendingPathComponent("displaced-confirmed.dmg"))
                try Data("different staging occupant".utf8).write(to: source, options: .withoutOverwriting)
            }
        }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let result = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        #expect(result.receipt?.state == .uncertain); #expect(sink.callCount == 0)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
        #expect(try Data(contentsOf: plan.recoveryURL.appendingPathComponent("displaced-confirmed.dmg")) == f.marker)
        #expect(try Data(contentsOf: plan.recoveryURL.appendingPathComponent(f.source.lastPathComponent)) == Data("different staging occupant".utf8))
    }
    @Test("Actual macOS Trash API and receipt restore only on owned CI fixture",
          .enabled(if: ProcessInfo.processInfo.environment["MOEKIT_INSTALLER_TRASH_FIXTURE"] == "1"))
    func nativeTrashRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted")
        let f = try InstallerFixture(name: "MoeKit-owned-\(UUID().uuidString).dmg", realTrash: true)
        let expected = try Data(contentsOf: f.source)
        try #require(expected == f.marker)
        let native = FixtureOnlyNativeTrashSink(marker: f.marker, allowedParent: f.recovery)
        let executor = f.executor(sink: native)
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let result = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        try #require(result.movedToTrash)
        let receipt = try #require(result.receipt), destination = try #require(receipt.trashURL)
        try #require(receipt.originalFile.matchesCaptured(#require(receipt.trashFile)))
        try #require(try Data(contentsOf: destination) == f.marker)
        // Two independent one-file confirmations with the same authored name
        // exercise native Trash collision handling without touching existing items.
        let second = try InstallerFixture(name: f.source.lastPathComponent, realTrash: true)
        let secondSink = FixtureOnlyNativeTrashSink(marker: second.marker, allowedParent: second.recovery)
        let secondExecutor = second.executor(sink: secondSink)
        let secondPlan = try await secondExecutor.prepare(selection: second.source, scope: second.scope)
        let secondMoved = try await secondExecutor.moveToTrash(planID: secondPlan.id, scope: secondPlan.scope)
        try #require(secondMoved.movedToTrash)
        let secondDestination = try #require(secondMoved.receipt?.trashURL)
        try #require(secondDestination.path != destination.path)
        try #require(try Data(contentsOf: destination) == f.marker)
        try #require(try Data(contentsOf: secondDestination) == second.marker)
        let secondContext = second.context
        let secondRestore = try await secondExecutor.prepareRestore(receiptID: secondPlan.id, context: secondContext)
        let secondRestored = try await secondExecutor.restore(planID: secondRestore.id, context: secondContext)
        try #require(secondRestored.receipt?.state == .restored)
        try #require(try Data(contentsOf: second.source) == second.marker)
        let context = f.context
        let restore = try await executor.prepareRestore(receiptID: receipt.id, context: context)
        let restored = try await executor.restore(planID: restore.id, context: context)
        try #require(restored.receipt?.state == .restored)
        try #require(try Data(contentsOf: f.source) == f.marker)
        try f.checkSentinel()
        try InstallerNativeFixtureEvidence.record(kind: "native-trash", detail: [
            "result": "verified-trash-and-restore", "sourceDevice": String(plan.file.device),
            "sourceInode": String(plan.file.inode), "operationID": receipt.id.uuidString, "duplicateNamesPreserved": "true"])
    }
}

private struct FixtureOnlyNativeTrashSink: InstallerTrashSink {
    let marker: Data
    let allowedParent: URL
    func trash(_ url: URL) throws -> URL {
        guard url.deletingLastPathComponent().deletingLastPathComponent().path == allowedParent.path,
              UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil else { throw InstallerTrashFailure.protected }
        let parent = try InstallerDirectoryAnchor.open(url.deletingLastPathComponent())
        let fd = try InstallerFileDescriptor(parent: parent, name: url.lastPathComponent)
        let expected = try InstallerFileAccess.snapshot(fd.fd)
        try InstallerFileAccess.validateRegular(expected)
        guard expected.bytes == marker.count, try Data(contentsOf: url) == marker,
              expected == (try InstallerFileAccess.snapshotAt(parent.fd, url.lastPathComponent)) else { throw InstallerTrashFailure.changed }
        return try NativeInstallerTrashSink().trash(url)
    }
}

/// Full builds include this suite; the targeted ASan job deliberately tests the
/// native guards separately without downloading/running the upstream analyzer.
@Suite("Live Mole selection to native installer operation", .serialized)
struct InstallerLiveMoleFlowTests {
    @Test("Production ancestry rejects a write ACL above private staging without moving the installer",
          .enabled(if: ProcessInfo.processInfo.environment["MOEKIT_INSTALLER_TRASH_FIXTURE"] == "1"))
    func unsafeRecoveryAncestor() async throws {
        let f = try InstallerFixture(hostedHomeFixture: true)
        let environment = InstallerTrashEnvironment(downloads: f.downloads, recoveryRoot: f.recovery,
            trash: f.trash, enforceLocalVolume: true, enforceTrustedAncestry: true)
        let executor = NativeInstallerTrashExecutor(environment: environment,
            evidence: InstallerFixtureEvidence(result: .noUseObserved), sink: InstallerFixtureSink(f.trash), nativeExecutionEnabled: true)
        let support = try InstallerDirectoryAnchor.open(f.base.appendingPathComponent("Support"))
        try support.validateTrustedMutationAncestry()
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::allow:delete_child\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try #require(acl_set_fd_np(support.fd, acl, ACL_TYPE_EXTENDED) == 0)
        #expect(throws: InstallerTrashFailure.unsupported) { try support.validateTrustedMutationAncestry() }
        await #expect(throws: InstallerTrashFailure.unsupported) { try await executor.moveToTrash(planID: plan.id, scope: plan.scope) }
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        #expect(try Data(contentsOf: f.source) == f.marker)
        try f.checkSentinel()
    }
    @Test("A late write ACL above staging prevents native Trash and preserves captured bytes",
          .enabled(if: ProcessInfo.processInfo.environment["MOEKIT_INSTALLER_TRASH_FIXTURE"] == "1"))
    func lateUnsafeRecoveryAncestor() async throws {
        let f = try InstallerFixture(hostedHomeFixture: true)
        let environment = InstallerTrashEnvironment(downloads: f.downloads, recoveryRoot: f.recovery,
            trash: f.trash, enforceLocalVolume: true, enforceTrustedAncestry: true)
        let supportURL = f.base.appendingPathComponent("Support")
        let executor = NativeInstallerTrashExecutor(environment: environment,
            evidence: InstallerFixtureEvidence(result: .noUseObserved), sink: InstallerFixtureSink(f.trash), nativeExecutionEnabled: true) { point in
                guard point == .beforeTrash else { return }
                let support = try InstallerDirectoryAnchor.open(supportURL)
                let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::allow:delete_child\n"))
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                try #require(acl_set_fd_np(support.fd, acl, ACL_TYPE_EXTENDED) == 0)
            }
        let plan = try await executor.prepare(selection: f.source, scope: f.scope)
        let outcome = try await executor.moveToTrash(planID: plan.id, scope: plan.scope)
        #expect(!outcome.movedToTrash && outcome.requiresRecovery)
        #expect(try Data(contentsOf: plan.recoveryURL.appendingPathComponent(f.source.lastPathComponent)) == f.marker)
        #expect(!FileManager.default.fileExists(atPath: f.trash.appendingPathComponent(f.source.lastPathComponent).path))
        try f.checkSentinel()
    }
    @Test("Official Mole live result supplies the exact native fixture selection",
          .enabled(if: ProcessInfo.processInfo.environment["MOEKIT_INSTALLER_TRASH_FIXTURE"] == "1"))
    func liveMoleToTrashAndRestore() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted")
        let resource = try #require(Bundle(for: InstallerLiveMoleBundle.self).url(forResource: "MoleAnalyzerFixturePath", withExtension: "txt"))
        let binary = try String(contentsOf: resource, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let f = try InstallerFixture(name: "MoeKit-live-Mole-owned-\(UUID().uuidString).dmg", realTrash: true, hostedHomeFixture: true)
        let analyzer = MoleAnalysisExecutor(privateSessionParent: f.base.appendingPathComponent("analysis-session"))
        let analysisPlan = try await analyzer.prepare(executable: URL(fileURLWithPath: binary), directory: f.downloads)
        let live = try await analyzer.run(analysisPlan)
        try #require(live.report.coverage == .known)
        let selected = try #require(live.report.entries.first(where: { $0.path == f.source.path && !$0.isDirectory && $0.coverage == .known }))
        let measuredBytes = try #require(selected.measuredBytes)
        try #require(measuredBytes == Int64(f.marker.count))
        let scope = InstallerTrashScope(generation: UUID(), liveAnalysisID: UUID(), liveDirectory: live.directory,
            liveEntryPaths: Set(live.report.entries.map(\.path)), protectedPaths: [], catalogIsKnown: true)
        let sink = FixtureOnlyNativeTrashSink(marker: f.marker, allowedParent: f.recovery)
        let productionVolumeEnvironment = InstallerTrashEnvironment(downloads: f.downloads, recoveryRoot: f.recovery,
            trash: f.trash, enforceLocalVolume: true, enforceTrustedAncestry: true)
        let executor = NativeInstallerTrashExecutor(environment: productionVolumeEnvironment,
            evidence: InstallerFixtureEvidence(result: .noUseObserved), sink: sink, nativeExecutionEnabled: true)
        let plan: InstallerTrashPlan
        do {
            plan = try await executor.prepare(selection: URL(fileURLWithPath: selected.path), scope: scope)
        } catch {
            let directory = try volumeDescription(f.downloads)
            let file = try volumeDescription(f.source)
            throw InstallerUseReadError.unavailable("Production planner refused owned fixture: \(error). Directory volume: \(directory). File volume: \(file)")
        }
        let moved = try await executor.moveToTrash(planID: plan.id, scope: scope)
        try #require(moved.movedToTrash)
        let context = f.context
        let restore = try await executor.prepareRestore(receiptID: plan.id, context: context)
        let restored = try await executor.restore(planID: restore.id, context: context)
        try #require(restored.receipt?.state == .restored)
        try #require(try Data(contentsOf: f.source) == f.marker)
        try f.checkSentinel()
        try InstallerNativeFixtureEvidence.record(kind: "live-mole", detail: [
            "result": "verified-live-selection-trash-and-restore", "sourceDevice": String(plan.file.device),
            "sourceInode": String(plan.file.inode), "release": live.release.version])
    }
    private func volumeDescription(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .isUbiquitousItemKey])
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        var fs = statfs()
        try #require(fstatfs(fd, &fs) == 0)
        let type = withUnsafeBytes(of: &fs.f_fstypename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return "type=\(type), flags=\(fs.f_flags), local=\(String(describing: values.volumeIsLocal)), internal=\(String(describing: values.volumeIsInternal)), removable=\(String(describing: values.volumeIsRemovable)), ejectable=\(String(describing: values.volumeIsEjectable)), ubiquitous=\(String(describing: values.isUbiquitousItem))"
    }
}
private final class InstallerLiveMoleBundle: NSObject {}
