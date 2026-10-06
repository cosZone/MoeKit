import Darwin
import Foundation
import Testing
@testable import MoeKit

@Suite("Git worktree finish authority")
struct GitWorktreeFinishAuthorityTests {
    @Test("Initialization and unknown operation IDs do not create recovery data")
    func inert() async throws {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-Finish-Inert-" + UUID().uuidString)
        let executor = NativeGitWorktreeFinishExecutor(catalogDirectory: absent)
        await #expect(throws: GitCleanupFailure.expired) { try await executor.merge(UUID(), permit: GitCleanupPermit()) }
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }
    @Test("Fresh index drops all stat cache fields and preserves the exact tree")
    func freshIndex() throws {
        let parsed = GitPlainIndex(entries: [.init(path: "hello.txt", oid: "ce013625030ba8dba906f756967f9e9ca394464a", executable: false)],
                                   treeOID: "aaa96ced2d9a1c8e72c56b253a0e2fe78393feb7")
        let bytes = try GitFinishIO.freshIndex(parsed)
        #expect(try GitPlainIndex.parse(bytes).treeOID == parsed.treeOID)
        #expect(try GitPlainIndex.parse(bytes).entries == parsed.entries)
        if !parsed.entries.isEmpty { #expect(bytes[12..<36].allSatisfy { $0 == 0 }) }
    }
}

@Suite("Git worktree finish native synthetic fixtures", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MOEKIT_GIT_NATIVE_FIXTURE"] == "1"))
struct GitWorktreeFinishExecutorTests {
    private func request(_ fixture: GitCleanupNativeFixture, target: String = "main") -> GitWorktreeFinishRequest {
        .init(scope: fixture.root, project: fixture.project, targetBranch: target)
    }
    private func advance(_ fixture: GitCleanupNativeFixture) throws -> String {
        try Data("completed source change\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.txt"))
        try FileManager.default.createDirectory(at: fixture.worktree.appendingPathComponent("new"), withIntermediateDirectories: false)
        try Data("new nested content\n".utf8).write(to: fixture.worktree.appendingPathComponent("new/result.txt"))
        try fixture.git(["add", "--", "tracked.txt", "new/result.txt"], at: fixture.worktree)
        try fixture.git(["commit", "-m", "Synthetic completed work"], at: fixture.worktree)
        return try fixture.git(["rev-parse", "HEAD"], at: fixture.worktree).trimmingCharacters(in: .newlines)
    }
    @Test("Fast-forward primary checkout, verify with real Git, separately retire and restore source")
    func primaryEndToEnd() async throws {
        let fixture = try GitCleanupNativeFixture(); defer { fixture.remove() }
        let oid = try advance(fixture)
        let originalIndex = try Data(contentsOf: fixture.common.appendingPathComponent("index"))
        let originalRef = try Data(contentsOf: fixture.common.appendingPathComponent("refs/heads/main"))
        let executor = NativeGitWorktreeFinishExecutor(catalogDirectory: fixture.catalog)
        let plan = try await executor.prepare(request(fixture))
        #expect(plan.canMerge && plan.uniqueCommitCount == 1)
        #expect(plan.sourceStatus.clean && plan.targetStatus?.clean == true)
        #expect(plan.targetWorktree == fixture.main)
        let result = try await executor.merge(plan.id, permit: GitCleanupPermit())
        #expect(result.verifiedOID == oid)
        #expect(try fixture.git(["rev-parse", "HEAD"], at: fixture.main).trimmingCharacters(in: .newlines) == oid)
        #expect(try fixture.git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.main).isEmpty)
        #expect(try Data(contentsOf: fixture.main.appendingPathComponent("new/result.txt")) == Data("new nested content\n".utf8))
        #expect(try Data(contentsOf: result.recovery.appendingPathComponent("previous/tracked.txt")) == fixture.marker)
        #expect(try Data(contentsOf: result.recovery.appendingPathComponent("previous-index")) == originalIndex)
        #expect(try Data(contentsOf: result.recovery.appendingPathComponent("previous-ref")) == originalRef)
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.common.appendingPathComponent("index.lock").path))
        await #expect(throws: GitCleanupFailure.expired) { try await executor.merge(plan.id, permit: GitCleanupPermit()) }
        let cleanup = fixture.executor()
        let retirement = try await cleanup.prepare(fixture.request())
        let receipt = try await cleanup.execute(retirement.id, permit: GitCleanupPermit())
        let retiredSeparately = !FileManager.default.fileExists(atPath: fixture.worktree.path)
        #expect(retiredSeparately)
        try await cleanup.restore(receipt.id, permit: GitCleanupPermit())
        #expect(try fixture.git(["status", "--porcelain=v1"], at: fixture.worktree).isEmpty)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("outside-sentinel")) == fixture.marker)
        let env = ProcessInfo.processInfo.environment
        let sha = try #require(env["MOEKIT_INSTALLER_SOURCE_SHA"])
        let evidencePath = try #require(env["MOEKIT_INSTALLER_EVIDENCE_DIR"])
        try #require(sha.count == 40 && sha.allSatisfy(\.isHexDigit))
        let checks: [String: Bool] = [
            "fastForward": result.verifiedOID == oid && plan.targetOID != oid,
            "primaryClean": try fixture.git(["status", "--porcelain=v1", "--untracked-files=all"], at: fixture.main).isEmpty,
            "retainedPreviousFiles": try Data(contentsOf: result.recovery.appendingPathComponent("previous/tracked.txt")) == fixture.marker,
            "retainedPreviousIndex": try Data(contentsOf: result.recovery.appendingPathComponent("previous-index")) == originalIndex,
            "retainedPreviousRef": try Data(contentsOf: result.recovery.appendingPathComponent("previous-ref")) == originalRef,
            "separateRetirement": retiredSeparately,
            "separateRestore": FileManager.default.fileExists(atPath: fixture.worktree.path),
            "outsideUntouched": try Data(contentsOf: fixture.root.appendingPathComponent("outside-sentinel")) == fixture.marker]
        try #require(checks.values.allSatisfy { $0 })
        var record: [String: Any] = checks.mapValues { $0 as Any }
        record["schema"] = 1; record["sourceSHA"] = sha
        record["sourceDevice"] = String(fixture.rootIdentity.device); record["sourceInode"] = String(fixture.rootIdentity.inode)
        record["previousOID"] = plan.targetOID; record["verifiedOID"] = oid
        let evidence = try InstallerDirectoryAnchor.open(URL(fileURLWithPath: evidencePath))
        try InstallerFileAccess.validatePrivate(evidence.fd, directory: true)
        try GitFinishIO.writeNew(JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), parent: evidence, name: "git-finish-native.json")
    }
    @Test("Unchecked-out branch fast-forward leaves the primary files and index untouched")
    func unoccupiedTarget() async throws {
        let fixture = try GitCleanupNativeFixture(); defer { fixture.remove() }
        try fixture.git(["branch", "integration"], at: fixture.main)
        let original = try Data(contentsOf: fixture.common.appendingPathComponent("index")), oid = try advance(fixture)
        let executor = NativeGitWorktreeFinishExecutor(catalogDirectory: fixture.catalog)
        let plan = try await executor.prepare(request(fixture, target: "integration"))
        #expect(plan.targetWorktree == nil)
        _ = try await executor.merge(plan.id, permit: GitCleanupPermit())
        #expect(try fixture.git(["rev-parse", "integration"], at: fixture.main).trimmingCharacters(in: .newlines) == oid)
        #expect(try Data(contentsOf: fixture.common.appendingPathComponent("index")) == original)
        try fixture.assertSentinel()
    }
    @Test("Source extras and target changes are shown and cannot authorize merge", arguments: ["source-extra", "source-ignored", "target-dirty", "source-staged"])
    func dirty(_ scenario: String) async throws {
        let fixture = try GitCleanupNativeFixture(); defer { fixture.remove() }
        _ = try advance(fixture)
        switch scenario {
        case "source-extra": try fixture.marker.write(to: fixture.worktree.appendingPathComponent("untracked.txt"))
        case "source-ignored": try fixture.marker.write(to: fixture.worktree.appendingPathComponent("ignored.txt"))
        case "target-dirty": try Data("target local edit\n".utf8).write(to: fixture.main.appendingPathComponent("tracked.txt"))
        default:
            try Data("source staged edit\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.txt"))
            try fixture.git(["add", "--", "tracked.txt"], at: fixture.worktree)
        }
        let executor = NativeGitWorktreeFinishExecutor(catalogDirectory: fixture.catalog)
        let plan = try await executor.prepare(request(fixture))
        #expect(!plan.canMerge && !plan.blockers.isEmpty)
        if scenario.hasPrefix("source-") && scenario != "source-staged" { #expect(plan.sourceStatus.untrackedOrIgnoredCount == 1) }
        if scenario == "source-staged" { #expect(plan.sourceStatus.stagedChanges) }
        await #expect(throws: GitCleanupFailure.expired) { try await executor.merge(plan.id, permit: GitCleanupPermit()) }
        #expect(!FileManager.default.fileExists(atPath: plan.recovery.path))
    }
    @Test("Divergence stops without creating a merge commit or touching either checkout")
    func divergence() async throws {
        let fixture = try GitCleanupNativeFixture(); defer { fixture.remove() }
        _ = try advance(fixture)
        try Data("independent target\n".utf8).write(to: fixture.main.appendingPathComponent("tracked.txt"))
        try fixture.git(["add", "--", "tracked.txt"], at: fixture.main)
        try fixture.git(["commit", "-m", "Divergent target"], at: fixture.main)
        let executor = NativeGitWorktreeFinishExecutor(catalogDirectory: fixture.catalog)
        let plan = try await executor.prepare(request(fixture))
        #expect(!plan.canMerge && plan.uniqueCommitCount == 1)
        #expect(plan.blockers.contains { $0.contains("diverged") })
        #expect(!FileManager.default.fileExists(atPath: plan.recovery.path))
    }
    @Test("Fresh changes and cancelled permits invalidate a reviewed plan")
    func stale() async throws {
        let fixture = try GitCleanupNativeFixture(); defer { fixture.remove() }
        _ = try advance(fixture)
        let executor = NativeGitWorktreeFinishExecutor(catalogDirectory: fixture.catalog)
        let plan = try await executor.prepare(request(fixture))
        try fixture.marker.write(to: fixture.worktree.appendingPathComponent("after-review.txt"))
        await #expect(throws: GitCleanupFailure.changed) { try await executor.merge(plan.id, permit: GitCleanupPermit()) }
        #expect(!FileManager.default.fileExists(atPath: plan.recovery.path))
    }
    @Test("Partial application retains old files, ref, both worktrees and recovery locks")
    func retainedPartial() async throws {
        let fixture = try GitCleanupNativeFixture(); defer { fixture.remove() }
        _ = try advance(fixture)
        let originalRef = try Data(contentsOf: fixture.common.appendingPathComponent("refs/heads/main"))
        let executor = NativeGitWorktreeFinishExecutor(catalogDirectory: fixture.catalog, checkpoint: { point in
            if point == .afterTargetFilesRetained { throw GitCleanupFailure.changed }
        })
        let plan = try await executor.prepare(request(fixture))
        await #expect(throws: GitCleanupFailure.partial(plan.recovery.path)) { try await executor.merge(plan.id, permit: GitCleanupPermit()) }
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("previous/tracked.txt")) == fixture.marker)
        #expect(try Data(contentsOf: fixture.common.appendingPathComponent("refs/heads/main")) == originalRef)
        #expect(FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(FileManager.default.fileExists(atPath: fixture.common.appendingPathComponent("index.lock").path))
        #expect(FileManager.default.fileExists(atPath: plan.recovery.appendingPathComponent("receipt-retained-partial.json").path))
    }
    @Test("Fast-forward preserves commits without running hooks or configured signing programs")
    func noRepositoryPrograms() async throws {
        let fixture = try GitCleanupNativeFixture(); defer { fixture.remove() }
        let oid = try advance(fixture)
        let hooks = fixture.common.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
        let marker = fixture.root.appendingPathComponent("hook-was-run")
        let body = Data(("#!/bin/sh\nprintf unsafe > '" + marker.path + "'\n").utf8)
        for name in ["post-merge", "post-checkout", "reference-transaction"] {
            let file = hooks.appendingPathComponent(name)
            try body.write(to: file, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        try fixture.git(["config", "commit.gpgSign", "true"], at: fixture.main)
        try fixture.git(["config", "gpg.program", marker.path], at: fixture.main)
        let executor = NativeGitWorktreeFinishExecutor(catalogDirectory: fixture.catalog)
        let plan = try await executor.prepare(request(fixture))
        let result = try await executor.merge(plan.id, permit: GitCleanupPermit())
        #expect(result.verifiedOID == oid)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
    @Test("Packed refs, hooksPath, filters, and symlink working files refuse honestly", arguments: ["packed", "hooksPath", "filter", "symlink"])
    func unsupported(_ scenario: String) async throws {
        let fixture = try GitCleanupNativeFixture(); defer { fixture.remove() }
        _ = try advance(fixture)
        switch scenario {
        case "packed": try fixture.git(["pack-refs", "--all"], at: fixture.main)
        case "hooksPath": try fixture.git(["config", "core.hooksPath", "/untrusted/hooks"], at: fixture.main)
        case "filter": try fixture.git(["config", "filter.untrusted.clean", "untrusted-command"], at: fixture.main)
        default: try FileManager.default.createSymbolicLink(at: fixture.worktree.appendingPathComponent("link"), withDestinationURL: fixture.main)
        }
        let executor = NativeGitWorktreeFinishExecutor(catalogDirectory: fixture.catalog)
        await #expect(throws: (any Error).self) { try await executor.prepare(request(fixture)) }
        try fixture.assertSentinel()
    }
}
