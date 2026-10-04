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
    let marker: Data
    func trash(_ url: URL) throws -> URL {
        let directory = try InstallerDirectoryAnchor.open(url)
        try #require(identity.matchesCaptured(InstallerFileAccess.snapshot(directory.fd)))
        try #require(CleanupFiles.names(directory) == ["owned.bin"])
        let file = try InstallerFileDescriptor(parent: directory, name: "owned.bin")
        try #require(BoundedRegularFileReader.read(descriptor: file.fd, maximumBytes: 1024) == marker)
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
    func sentinelUnchanged() throws { #expect(try Data(contentsOf: sentinel) == marker) }
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
        #expect(receipt.canDeletePermanently)
        let deletion = try await executor.prepareRecovery(receiptID: receipt.id, action: .deletePermanently, context: context)
        #expect(FileManager.default.fileExists(atPath: try #require(receipt.payloadURL).path))
        let removed = try await executor.applyRecovery(planID: deletion.id, context: context)
        #expect(removed.items.first?.succeeded == true)
        #expect(removed.items.first?.receipt?.state == .deleted)
        #expect(removed.items.first?.receipt?.canRestore == false)
        #expect(!FileManager.default.fileExists(atPath: try #require(receipt.payloadURL).path))
        await #expect(throws: (any Error).self) { try await executor.applyRecovery(planID: deletion.id, context: context) }
        #expect(try Data(contentsOf: unrelatedTrash) == f.marker)
        try f.sentinelUnchanged()
    }
    @Test("Changed selection, unknown catalog and protected project roots never authorize cleanup")
    func contextGuards() async throws {
        let f = try CacheFixture(), a = try f.folder("cache"), executor = f.executor()
        let unknown = CleanupContext(generation: UUID(), protectedPaths: [], catalogIsKnown: false)
        await #expect(throws: (any Error).self) { try await executor.inspect(root: f.caches, context: unknown) }
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
        await #expect(throws: (any Error).self) { try await executor.inspect(root: f.caches, context: f.context) }
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
    @Test("Actual native Trash and restore use only a uniquely owned fixture", .enabled(if: ProcessInfo.processInfo.environment["MOEKIT_CACHE_NATIVE_FIXTURE"] == "1"))
    func actualNativeTrash() async throws {
        let f = try CacheFixture(realTrash: true), a = try f.folder("Owned-Cache-\(UUID().uuidString)")
        let original = try InstallerDirectoryAnchor.open(a)
        let identity = try InstallerFileAccess.snapshot(original.fd)
        let expectedMarker = f.marker
        let executor = f.executor(sink: VerifiedCacheNativeSink(identity: identity, marker: expectedMarker)), context = f.context
        let plan = try await f.plan(executor, selected: [a], context: context)
        let result = try await executor.moveToTrash(planID: plan.id, context: context)
        let receipt = try #require(result.items.first?.receipt)
        #expect(receipt.state == .trashed)
        #expect(receipt.payloadURL?.deletingLastPathComponent().path == f.trash.path)
        let restore = try await executor.prepareRecovery(receiptID: receipt.id, action: .restore, context: context)
        let restored = try await executor.applyRecovery(planID: restore.id, context: context)
        #expect(restored.items.first?.succeeded == true)
        #expect(try Data(contentsOf: a.appendingPathComponent("owned.bin")) == f.marker)
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
