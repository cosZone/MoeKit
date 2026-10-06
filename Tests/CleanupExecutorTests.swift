import Darwin
import Foundation
import Testing
@testable import MoeKit

private final class CacheFixtureSink: InstallerTrashSink, @unchecked Sendable {
    let destination: URL
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    init(_ destination: URL) { self.destination = destination }
    func trash(_ url: URL) throws -> URL {
        lock.withLock { count += 1 }
        let from = try InstallerDirectoryAnchor.open(url.deletingLastPathComponent())
        let to = try InstallerDirectoryAnchor.open(destination)
        try InstallerFileAccess.exclusiveMove(from: from, name: url.lastPathComponent, to: to, destinationName: url.lastPathComponent)
        return destination.appendingPathComponent(url.lastPathComponent)
    }
}

private struct VerifiedCacheNativeSink: InstallerTrashSink {
    let identity: InstallerFileSnapshot
    let fixtureRoot: URL
    let fixtureRootIdentity: InstallerFileSnapshot
    let markerIdentity: InstallerFileSnapshot
    let marker: Data
    func trash(_ url: URL) throws -> URL {
        let root = try InstallerDirectoryAnchor.open(fixtureRoot)
        let rootActual = try InstallerFileAccess.snapshot(root.fd)
        try #require(fixtureRootIdentity.matchesDirectory(rootActual))
        let directory = try InstallerDirectoryAnchor.open(url)
        let directoryActual = try InstallerFileAccess.snapshot(directory.fd)
        try #require(identity.matchesCaptured(directoryActual))
        let names = try CleanupFiles.names(directory)
        try #require(names == ["owned.bin"])
        let file = try InstallerFileDescriptor(parent: directory, name: "owned.bin")
        let opened = try InstallerFileAccess.snapshot(file.fd)
        let named = try InstallerFileAccess.snapshotAt(directory.fd, "owned.bin")
        let bytes = try BoundedRegularFileReader.read(descriptor: file.fd, maximumBytes: 1024)
        try #require(markerIdentity == opened && markerIdentity == named)
        try #require(bytes == marker)
        return try NativeInstallerTrashSink().trash(url)
    }
}

private struct CacheFixture: Sendable {
    let base: URL, caches: URL, recovery: URL, trash: URL, sentinel: URL
    let marker: Data
    let productionPolicy: Bool
    init(realTrash: Bool = false) throws {
        productionPolicy = realTrash
        if realTrash {
            let env = ProcessInfo.processInfo.environment
            try #require(env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted" && env["MOEKIT_CACHE_NATIVE_FIXTURE"] == "1")
        }
        let temp = try MoleAnalysisFiles.canonicalURL(realTrash ? FileManager.default.homeDirectoryForCurrentUser : FileManager.default.temporaryDirectory)
        base = temp.appendingPathComponent("MoeKit-Cache-Owned-\(UUID().uuidString)")
        caches = base.appendingPathComponent("Caches")
        recovery = base.appendingPathComponent("Support/MoeKit/CacheRecovery")
        trash = realTrash ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") : base.appendingPathComponent("Trash")
        sentinel = base.appendingPathComponent("outside-sentinel")
        marker = Data("Owned cache fixture \(UUID().uuidString)".utf8)
        for url in [base, caches, base.appendingPathComponent("Support")] + (realTrash ? [] : [trash]) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try marker.write(to: sentinel, options: .withoutOverwriting)
    }
    var environment: CleanupEnvironment { .init(home: base, caches: caches, recovery: recovery, trash: trash, enforceProductionPolicy: productionPolicy) }
    var context: CleanupContext { .init(generation: UUID(), protectedPaths: [], catalogIsKnown: true) }
    func folder(_ name: String) throws -> URL {
        let url = caches.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try marker.write(to: url.appendingPathComponent("owned.bin"), options: .withoutOverwriting)
        return url
    }
    func executor(sink: (any InstallerTrashSink)? = nil,
                  hook: @escaping @Sendable (CleanupCheckpoint) throws -> Void = { _ in }) -> NativeCleanupExecutor {
        .init(environment: environment, sink: sink ?? CacheFixtureSink(trash), checkpoint: hook)
    }
    func sentinelUnchanged() throws { let bytes = try Data(contentsOf: sentinel); try #require(bytes == marker) }
    func plan(_ executor: NativeCleanupExecutor, selected: [URL], context: CleanupContext) async throws -> CleanupPlan {
        let report = try await executor.inspect(root: caches, context: context)
        return try await executor.prepare(inspectionID: report.id, selectedPaths: Set(selected.map(\.path)), context: context)
    }
    // Fixtures are uniquely created, retained, and never recursively cleaned by
    // the test harness. Irreversible tests remove only their approved manifest.
}

@Suite("Confirmed native cache cleanup", .serialized)
struct CleanupExecutorTests {
    @Test("Read-only multi-cache plan creates no journal and cancelled token cannot run")
    func planIsInert() async throws {
        let f = try CacheFixture(), a = try f.folder("cache one 空格\n"), b = try f.folder("cache two")
        let executor = f.executor(), context = f.context
        let plan = try await f.plan(executor, selected: [a, b], context: context)
        #expect(plan.targets.count == 2)
        #expect(plan.targets.allSatisfy { $0.manifest.entries.count == 2 })
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        await executor.discardPlans()
        await #expect(throws: (any Error).self) { try await executor.moveToTrash(planID: plan.id, context: context) }
        #expect(try Data(contentsOf: a.appendingPathComponent("owned.bin")) == f.marker)
        try f.sentinelUnchanged()
    }
    @Test("Unreadable unrelated Trash does not prevent cache inspection or preparation")
    func unrelatedTrashReadDenial() async throws {
        let f = try CacheFixture(), a = try f.folder("MiniLauncher"), executor = f.executor(), context = f.context
        try #require(chmod(f.trash.path, 0o000) == 0)
        defer { _ = chmod(f.trash.path, 0o700) }
        let blockedOpen = open(f.trash.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if blockedOpen >= 0 { close(blockedOpen) }
        try #require(blockedOpen < 0) // This is an unreadable owned fixture, not real Trash.
        let report = try await executor.inspect(root: f.caches, context: context)
        let row = try #require(report.candidates.first)
        #expect(row.isEligible)
        #expect(row.sizeEstimate?.logicalBytes == Int64(f.marker.count))
        let plan = try await executor.prepare(inspectionID: report.id, selectedPaths: [a.path], context: context)
        #expect(plan.targets.count == 1)
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        try f.sentinelUnchanged()
    }
    @Test("Protected no-follow metadata still rejects direct, containing, and contained overlaps")
    func protectedMetadataOverlap() throws {
        let f = try CacheFixture(), a = try f.folder("cache")
        let nested = a.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o000])
        defer { _ = chmod(nested.path, 0o700) }
        for path in [a.path, f.caches.path, nested.path] {
            #expect(throws: (any Error).self) { try CleanupFiles.protect(a, paths: [path]) }
        }
        let alias = f.base.appendingPathComponent("protected-alias")
        try #require(symlink(nested.path, alias.path) == 0)
        #expect(throws: (any Error).self) { try CleanupFiles.protect(a, paths: [alias.path]) }
        try f.sentinelUnchanged()
    }
    @Test("A candidate's mutable ACL does not erase its readable size or authorize cleanup")
    func aclReadOnlySize() async throws {
        let f = try CacheFixture(), a = try f.folder("readable-cache")
        let fd = open(a.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0); defer { close(fd) }
        let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::allow:write\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try #require(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0)
        let report = try await f.executor().inspect(root: f.caches, context: f.context)
        #expect(report.candidates.first?.isEligible == false)
        #expect(report.candidates.first?.sizeEstimate?.logicalBytes == Int64(f.marker.count))
        #expect(report.candidates.first?.blocker?.contains(a.path) == true)
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
    }
    @Test("A writeable home ancestor affects cleanup eligibility, not metadata size")
    func ancestryReadOnlySize() async throws {
        let f = try CacheFixture(), a = try f.folder("readable-cache")
        try #require(chmod(f.base.path, 0o777) == 0)
        defer { _ = chmod(f.base.path, 0o700) }
        let env = CleanupEnvironment(home: f.base, caches: f.caches, recovery: f.recovery, trash: f.trash, enforceProductionPolicy: true)
        let report = try await NativeCleanupExecutor(environment: env).inspect(root: f.caches, context: f.context)
        #expect(report.candidates.first?.isEligible == false)
        #expect(report.candidates.first?.sizeEstimate?.logicalBytes == Int64(f.marker.count))
        #expect(try Data(contentsOf: a.appendingPathComponent("owned.bin")) == f.marker)
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
    }
    @Test("Batch moves only selected caches and independently confirmed restore preserves neighbors")
    func batchRestore() async throws {
        let f = try CacheFixture(), a = try f.folder("cache a"), b = try f.folder("cache b"), neighbor = try f.folder("unselected")
        let executor = f.executor(), context = f.context
        let plan = try await f.plan(executor, selected: [a, b], context: context)
        let result = try await executor.moveToTrash(planID: plan.id, context: context)
        #expect(result.items.count == 2 && result.items.allSatisfy(\.succeeded))
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(try Data(contentsOf: neighbor.appendingPathComponent("owned.bin")) == f.marker)
        await #expect(throws: (any Error).self) { try await executor.moveToTrash(planID: plan.id, context: context) }
        for item in result.items {
            let receipt = try #require(item.receipt)
            let restore = try await executor.prepareRecovery(receiptID: receipt.id, action: .restore, context: context)
            let restored = try await executor.applyRecovery(planID: restore.id, context: context)
            #expect(restored.items.first?.receipt?.state == .restored)
            #expect(try Data(contentsOf: receipt.target.originalURL.appendingPathComponent("owned.bin")) == f.marker)
        }
        #expect(try await executor.recoveryRecords().count == 2)
        try f.sentinelUnchanged()
    }
    @Test("Permanent removal consumes only a new selected-receipt confirmation; outside symlinks and hardlinks survive")
    func permanentConfirmedManifest() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), unrelatedTrash = f.trash.appendingPathComponent("other-user-trash")
        try f.marker.write(to: unrelatedTrash, options: .withoutOverwriting)
        let nested = a.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try #require(symlink(f.sentinel.path, nested.appendingPathComponent("outside-link").path) == 0)
        try #require(link(f.sentinel.path, nested.appendingPathComponent("outside-hardlink").path) == 0)
        try #require(link(f.sentinel.path, nested.appendingPathComponent("second-hardlink").path) == 0)
        let executor = f.executor(), context = f.context
        let plan = try await f.plan(executor, selected: [a], context: context)
        let moved = try await executor.moveToTrash(planID: plan.id, context: context)
        let receipt = try #require(moved.items.first?.receipt)
        try #require(receipt.canDeletePermanently)
        let deletion = try await executor.prepareRecovery(receiptID: receipt.id, action: .deletePermanently, context: context)
        #expect(FileManager.default.fileExists(atPath: try #require(receipt.payloadURL).path))
        let removed = try await executor.applyRecovery(planID: deletion.id, context: context)
        try #require(removed.items.first?.succeeded == true)
        try #require(removed.items.first?.receipt?.state == .deleted)
        try #require(removed.items.first?.receipt?.canRestore == false)
        let removedURL = try #require(receipt.payloadURL)
        try #require(!FileManager.default.fileExists(atPath: removedURL.path))
        await #expect(throws: (any Error).self) { try await executor.applyRecovery(planID: deletion.id, context: context) }
        let neighborBytes = try Data(contentsOf: unrelatedTrash)
        try #require(neighborBytes == f.marker)
        try f.sentinelUnchanged()
    }
    @Test("Changed selection, unknown catalog and protected project roots never authorize cleanup")
    func contextGuards() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), executor = f.executor()
        let unknown = CleanupContext(generation: UUID(), protectedPaths: [], catalogIsKnown: false)
        let unknownReport = try await executor.inspect(root: f.caches, context: unknown)
        #expect(unknownReport.candidates.first?.isEligible == false)
        #expect(unknownReport.candidates.first?.sizeEstimate?.logicalBytes == Int64(f.marker.count))
        await #expect(throws: (any Error).self) { try await executor.prepare(inspectionID: unknownReport.id, selectedPaths: [a.path], context: unknown) }
        let protected = CleanupContext(generation: UUID(), protectedPaths: [a.path], catalogIsKnown: true)
        let report = try await executor.inspect(root: f.caches, context: protected)
        #expect(report.candidates.first?.isEligible == false)
        let good = f.context, plan = try await f.plan(executor, selected: [a], context: good)
        await #expect(throws: (any Error).self) { try await executor.moveToTrash(planID: plan.id, context: f.context) }
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        try f.sentinelUnchanged()
    }
    @Test("Git metadata and protected credential names refuse complete candidate", arguments: [".git", ".env", ".ssh"])
    func nestedProtection(_ name: String) async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), executor = f.executor()
        try f.marker.write(to: a.appendingPathComponent(name), options: .withoutOverwriting)
        let report = try await executor.inspect(root: f.caches, context: f.context)
        #expect(report.candidates.first?.isEligible == false)
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
    }
    @Test("Enclosing Git and symlink roots are refused without following targets")
    func rootsRefuse() async throws {
        let f = try CacheFixture(), executor = f.executor()
        _ = try f.folder("cache")
        let alias = f.base.appendingPathComponent("alias")
        try #require(symlink(f.caches.path, alias.path) == 0)
        await #expect(throws: (any Error).self) { try await executor.inspect(root: alias, context: f.context) }
        try f.marker.write(to: f.base.appendingPathComponent(".git"), options: .withoutOverwriting)
        let report = try await executor.inspect(root: f.caches, context: f.context)
        #expect(report.candidates.first?.isEligible == false)
        #expect(report.candidates.first?.sizeEstimate?.logicalBytes == Int64(f.marker.count))
    }
    @Test("Tagged caches below bare Git repositories remain protected")
    func bareGitAncestor() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), executor = f.executor()
        try CleanupFiles.cacheSignature.write(to: a.appendingPathComponent("CACHEDIR.TAG"), options: .withoutOverwriting)
        try Data("ref: refs/heads/main\n".utf8).write(to: f.base.appendingPathComponent("HEAD"), options: .withoutOverwriting)
        for name in ["objects", "refs"] {
            try FileManager.default.createDirectory(at: f.base.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let report = try await executor.inspect(root: f.caches, context: f.context)
        #expect(report.candidates.first?.isEligible == false)
        #expect(report.candidates.first?.sizeEstimate?.logicalBytes == Int64(f.marker.count + CleanupFiles.cacheSignature.count))
        #expect(try Data(contentsOf: a.appendingPathComponent("owned.bin")) == f.marker)
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
    }

    @Test("System and authentication cache names remain protected", arguments: ["com.apple.sample", "bitwarden", "credential-cache", "MoeKit"])
    func sensitiveCacheNames(_ name: String) async throws {
        let f = try CacheFixture(), executor = f.executor()
        _ = try f.folder(name)
        let report = try await executor.inspect(root: f.caches, context: f.context)
        #expect(report.candidates.first?.isEligible == false)
    }
    @Test("Cache marker signature is checked and never bypasses Git protection")
    func markerEvidence() async throws {
        let f = try CacheFixture(), executor = f.executor()
        let container = f.base.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let cache = container.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let tag = cache.appendingPathComponent("CACHEDIR.TAG")
        try Data("invalid tag".utf8).write(to: tag, options: .withoutOverwriting)
        let invalid = try await executor.inspect(root: container, context: f.context)
        #expect(invalid.candidates.first?.isEligible == false)
        try CleanupFiles.cacheSignature.write(to: tag)
        let valid = try await executor.inspect(root: container, context: f.context)
        #expect(valid.candidates.first?.isEligible == true)
        try f.marker.write(to: cache.appendingPathComponent(".git"), options: .withoutOverwriting)
        let git = try await executor.inspect(root: container, context: f.context)
        #expect(git.candidates.first?.isEligible == false)
    }
    @Test("Fresh plan detects additions and changed contents before any mutation")
    func changedManifest() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), executor = f.executor(), context = f.context
        let plan = try await f.plan(executor, selected: [a], context: context)
        try f.marker.write(to: a.appendingPathComponent("unapproved.bin"), options: .withoutOverwriting)
        await #expect(throws: (any Error).self) { try await executor.moveToTrash(planID: plan.id, context: context) }
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
        try f.sentinelUnchanged()
    }
    @Test("Source replacement at capture cannot enter native Trash")
    func captureRace() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), saved = f.caches.appendingPathComponent("saved-original"), sink = CacheFixtureSink(f.trash)
        let executor = f.executor(sink: sink) { point in
            if case .beforeCapture = point {
                try FileManager.default.moveItem(at: a, to: saved)
                try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Data("replacement preserved".utf8).write(to: a.appendingPathComponent("replacement.bin"), options: .withoutOverwriting)
            }
        }
        let context = f.context, plan = try await f.plan(executor, selected: [a], context: context)
        let result = try await executor.moveToTrash(planID: plan.id, context: context)
        #expect(sink.calls == 0)
        #expect(result.items.first?.requiresRecovery == true)
        let payload = try #require(result.items.first?.receipt?.payloadURL)
        #expect(try Data(contentsOf: payload.appendingPathComponent("replacement.bin")) == Data("replacement preserved".utf8))
        #expect(try Data(contentsOf: saved.appendingPathComponent("owned.bin")) == f.marker)
        try f.sentinelUnchanged()
    }
    @Test("Restore collision preserves recreated cache and Trash contents")
    func restoreCollision() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), executor = f.executor(), context = f.context
        let plan = try await f.plan(executor, selected: [a], context: context)
        let result = try await executor.moveToTrash(planID: plan.id, context: context)
        let receipt = try #require(result.items.first?.receipt)
        _ = try f.folder("cache")
        await #expect(throws: (any Error).self) { try await executor.prepareRecovery(receiptID: receipt.id, action: .restore, context: context) }
        #expect(try Data(contentsOf: a.appendingPathComponent("owned.bin")) == f.marker)
        #expect(try Data(contentsOf: #require(receipt.payloadURL).appendingPathComponent("owned.bin")) == f.marker)
    }
    @Test("Changed Trash tree cannot be permanently removed")
    func changedTrash() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), executor = f.executor(), context = f.context
        let plan = try await f.plan(executor, selected: [a], context: context)
        let result = try await executor.moveToTrash(planID: plan.id, context: context)
        let receipt = try #require(result.items.first?.receipt), source = try #require(receipt.payloadURL)
        let deletion = try await executor.prepareRecovery(receiptID: receipt.id, action: .deletePermanently, context: context)
        try f.marker.write(to: source.appendingPathComponent("unapproved"), options: .withoutOverwriting)
        await #expect(throws: (any Error).self) { try await executor.applyRecovery(planID: deletion.id, context: context) }
        #expect(try Data(contentsOf: source.appendingPathComponent("owned.bin")) == f.marker)
        try f.sentinelUnchanged()
    }
    @Test("Unknown recovery record revokes all operations instead of falling back")
    func corruptRecord() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), executor = f.executor(), context = f.context
        let plan = try await f.plan(executor, selected: [a], context: context)
        let moved = try await executor.moveToTrash(planID: plan.id, context: context)
        let receipt = try #require(moved.items.first?.receipt)
        let bad = receipt.operationURL.appendingPathComponent(String(format: "%06d.cache.json", receipt.sequence + 1))
        try Data("{".utf8).write(to: bad, options: .withoutOverwriting)
        let rows = try await executor.recoveryRecords()
        #expect(rows.first?.receipt == nil)
        await #expect(throws: (any Error).self) { try await executor.prepareRecovery(receiptID: receipt.id, action: .deletePermanently, context: context) }
    }
    @Test("Leaf replacement before or after private capture never deletes replacement bytes", arguments: ["before", "after"])
    func leafRace(_ timing: String) async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), context = f.context
        let executor = f.executor(), plan = try await f.plan(executor, selected: [a], context: context)
        let moved = try await executor.moveToTrash(planID: plan.id, context: context)
        let receipt = try #require(moved.items.first?.receipt)
        let operation = receipt.operationURL
        let expectedSource = operation.appendingPathComponent(timing == "before" ? "delete-payload/owned.bin" : "delete-entry-000001")
        let preserved = operation.appendingPathComponent("race-original-preserved")
        let replacement = Data("Never delete unconfirmed replacement".utf8)
        let guarded = f.executor { checkpoint in
            let applies: Bool
            switch checkpoint {
            case .beforeLeafCapture: applies = timing == "before"
            case .afterLeafCapture: applies = timing == "after"
            default: applies = false
            }
            if applies {
                try FileManager.default.moveItem(at: expectedSource, to: preserved)
                try replacement.write(to: expectedSource, options: .withoutOverwriting)
            }
        }
        let deletion = try await guarded.prepareRecovery(receiptID: receipt.id, action: .deletePermanently, context: context)
        let result = try await guarded.applyRecovery(planID: deletion.id, context: context)
        #expect(result.items.first?.succeeded == false)
        #expect(result.items.first?.receipt?.state == .uncertain)
        #expect(try Data(contentsOf: operation.appendingPathComponent("delete-entry-000001")) == replacement)
        #expect(try Data(contentsOf: preserved) == f.marker)
        try f.sentinelUnchanged()
    }
    @Test("Late restore collision leaves a durable stage that a new exact confirmation can restore")
    func lateRestoreCollision() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), context = f.context
        let executor = f.executor(), plan = try await f.plan(executor, selected: [a], context: context)
        let moved = try await executor.moveToTrash(planID: plan.id, context: context)
        let receipt = try #require(moved.items.first?.receipt)
        let collision = f.executor { checkpoint in
            if case .beforeRestore = checkpoint {
                try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Data("new cache preserved".utf8).write(to: a.appendingPathComponent("new"), options: .withoutOverwriting)
            }
        }
        let first = try await collision.prepareRecovery(receiptID: receipt.id, action: .restore, context: context)
        let failed = try await collision.applyRecovery(planID: first.id, context: context)
        let retained = try #require(failed.items.first?.receipt)
        #expect(retained.state == .retained && retained.canRestore)
        #expect(try Data(contentsOf: #require(retained.payloadURL).appendingPathComponent("owned.bin")) == f.marker)
        let neighbor = f.caches.appendingPathComponent("new-cache-preserved")
        try FileManager.default.moveItem(at: a, to: neighbor)
        let clean = f.executor()
        let retry = try await clean.prepareRecovery(receiptID: receipt.id, action: .restore, context: context)
        let restored = try await clean.applyRecovery(planID: retry.id, context: context)
        #expect(restored.items.first?.succeeded == true)
        #expect(try Data(contentsOf: a.appendingPathComponent("owned.bin")) == f.marker)
        #expect(try Data(contentsOf: neighbor.appendingPathComponent("new")) == Data("new cache preserved".utf8))
    }
    @Test("Cancellation before permanent removal preserves a newly confirmable exact restore")
    func cancellationBeforeUnlink() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), context = f.context
        let executor = f.executor(), plan = try await f.plan(executor, selected: [a], context: context)
        let moved = try await executor.moveToTrash(planID: plan.id, context: context)
        let receipt = try #require(moved.items.first?.receipt)
        let cancelling = f.executor { checkpoint in
            if case .beforePermanentDelete = checkpoint { throw CancellationError() }
        }
        let deletion = try await cancelling.prepareRecovery(receiptID: receipt.id, action: .deletePermanently, context: context)
        let stopped = try await cancelling.applyRecovery(planID: deletion.id, context: context)
        let retained = try #require(stopped.items.first?.receipt)
        #expect(retained.state == .retained && retained.canRestore)
        #expect(!retained.canDeletePermanently)
        #expect(try Data(contentsOf: #require(retained.payloadURL).appendingPathComponent("owned.bin")) == f.marker)
        let restore = try await cancelling.prepareRecovery(receiptID: receipt.id, action: .restore, context: context)
        let restored = try await cancelling.applyRecovery(planID: restore.id, context: context)
        #expect(restored.items.first?.succeeded == true)
        #expect(try Data(contentsOf: a.appendingPathComponent("owned.bin")) == f.marker)
        try f.sentinelUnchanged()
    }

    @Test("A partial journal write latches the writer and revokes receipt authority")
    func journalWriteFailure() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), context = f.context
        let executor = f.executor(), plan = try await f.plan(executor, selected: [a], context: context)
        let moved = try await executor.moveToTrash(planID: plan.id, context: context)
        let receipt = try #require(moved.items.first?.receipt)
        do {
            let journal = try CleanupJournal(environment: f.environment, create: false, exclusive: true,
                                             afterRecordCreated: { throw CleanupFailure.journal })
            let operation = try journal.storage.operation(receipt.id)
            let proposed = receipt.advancing(.restoreCaptureIntent, payloadURL: receipt.payloadURL)
            #expect(throws: (any Error).self) { try journal.append(proposed, operation: operation) }
            #expect(!journal.isHealthy)
            #expect(throws: (any Error).self) { try journal.append(proposed, operation: operation) }
            #expect(throws: (any Error).self) { try journal.latest(receipt.id) }
        }
        let records = try await executor.recoveryRecords()
        #expect(records.first?.receipt == nil)
        #expect(try Data(contentsOf: #require(receipt.payloadURL).appendingPathComponent("owned.bin")) == f.marker)
        try f.sentinelUnchanged()
    }
    @Test("Own Trash namespace is protected even with a valid cache tag")
    func ownStorageProtection() async throws {
        let f = try CacheFixture(), context = f.context
        try CleanupFiles.cacheSignature.write(to: f.trash.appendingPathComponent("CACHEDIR.TAG"), options: .withoutOverwriting)
        let wider = CleanupEnvironment(home: f.base.deletingLastPathComponent(), caches: f.caches, recovery: f.recovery,
                                       trash: f.trash, enforceProductionPolicy: false)
        let executor = NativeCleanupExecutor(environment: wider, sink: CacheFixtureSink(f.trash))
        let report = try await executor.inspect(root: f.base, context: context)
        #expect(report.candidates.first(where: { $0.url.path == f.trash.path })?.isEligible == false)
        #expect(try Data(contentsOf: f.trash.appendingPathComponent("CACHEDIR.TAG")) == CleanupFiles.cacheSignature)
        try f.sentinelUnchanged()
    }

    @Test("Case and Unicode equivalent protection never widens selected scope")
    func aliasProtection() async throws {
        let f = try CacheFixture(), a = try f.folder("Café"), executor = f.executor()
        let alias = f.caches.appendingPathComponent("CAFE\u{301}")
        let scope = CleanupContext(generation: UUID(), protectedPaths: [alias.path], catalogIsKnown: true)
        let report = try await executor.inspect(root: f.caches, context: scope)
        #expect(report.candidates.first(where: { $0.url.path == a.path })?.isEligible == false)
        #expect(try Data(contentsOf: a.appendingPathComponent("owned.bin")) == f.marker)
    }
    @Test("Complete manifest and permanent-directory budgets fail before authorization")
    func boundedInventory() throws {
        let f = try CacheFixture(), a = try f.folder("cache")
        let directory = try InstallerDirectoryAnchor.open(a)
        #expect(throws: (any Error).self) {
            try CleanupFiles.manifest(directory, environment: f.environment, maximumEntries: 1)
        }
        let identity = try InstallerFileAccess.snapshot(directory.fd)
        let tooMany = CleanupManifest(entries: (0...CleanupPermanentRemoval.maximumDirectories).map {
            CleanupEntry(relativePath: String($0), kind: .directory, identity: identity, linkDestination: nil)
        }, logicalBytes: 0)
        #expect(throws: (any Error).self) { try CleanupPermanentRemoval.preflight(tooMany) }
        #expect(!FileManager.default.fileExists(atPath: f.recovery.path))
    }

    @Test("Actual native Trash and restore use only a uniquely owned fixture", .enabled(if: ProcessInfo.processInfo.environment["MOEKIT_CACHE_NATIVE_FIXTURE"] == "1"))
    func actualNativeTrash() async throws {
        let f = try CacheFixture(realTrash: true), a = try f.folder("Owned-Cache-\(UUID().uuidString)")
        let original = try InstallerDirectoryAnchor.open(a)
        let identity = try InstallerFileAccess.snapshot(original.fd)
        let expectedMarker = f.marker
        let markerIdentity = try InstallerFileAccess.snapshotAt(original.fd, "owned.bin")
        let fixtureRootIdentity = try InstallerDirectoryAnchor.open(f.base).identity
        let executor = f.executor(sink: VerifiedCacheNativeSink(identity: identity, fixtureRoot: f.base, fixtureRootIdentity: fixtureRootIdentity, markerIdentity: markerIdentity, marker: expectedMarker)), context = f.context
        let plan = try await f.plan(executor, selected: [a], context: context)
        let result = try await executor.moveToTrash(planID: plan.id, context: context)
        let receipt = try #require(result.items.first?.receipt)
        try #require(receipt.state == .trashed)
        try #require(receipt.payloadURL?.deletingLastPathComponent().path == f.trash.path)
        let restore = try await executor.prepareRecovery(receiptID: receipt.id, action: .restore, context: context)
        let restored = try await executor.applyRecovery(planID: restore.id, context: context)
        try #require(restored.items.first?.succeeded == true)
        let restoredBytes = try Data(contentsOf: a.appendingPathComponent("owned.bin"))
        try #require(restoredBytes == f.marker)
        try f.sentinelUnchanged()
        try await permanentConfirmedManifest()
        let env = ProcessInfo.processInfo.environment
        let sha = try #require(env["MOEKIT_INSTALLER_SOURCE_SHA"])
        let evidencePath = try #require(env["MOEKIT_INSTALLER_EVIDENCE_DIR"])
        try #require(sha.count == 40 && sha.allSatisfy(\.isHexDigit))
        let evidence = try InstallerDirectoryAnchor.open(URL(fileURLWithPath: evidencePath))
        try InstallerFileAccess.validatePrivate(evidence.fd, directory: true)
        let bytes = try JSONSerialization.data(withJSONObject: ["schema": 1, "sourceSHA": sha,
            "nativeTrashRestore": true, "productionPolicy": true, "ownedManifestPurge": true,
            "sourceDevice": String(identity.device), "sourceInode": String(identity.inode)])
        let fd = openat(evidence.fd, "cache-native.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == bytes.count)
        try #require(fsync(fd) == 0)
    }
}
