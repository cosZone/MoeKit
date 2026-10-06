import Darwin
import Foundation
import Testing
@testable import MoeKit

@Suite("Git cleanup one-use authority")
struct GitCleanupAuthorityTests {
    @Test("Permits are one-use and explicit invalidation is irreversible")
    func permits() throws {
        let consumed = GitCleanupPermit()
        try consumed.consume()
        #expect(throws: GitCleanupFailure.expired) { try consumed.consume() }
        consumed.invalidate()
        #expect(throws: GitCleanupFailure.expired) { try consumed.consume() }
        let cancelled = GitCleanupPermit()
        cancelled.invalidate(); cancelled.invalidate()
        #expect(throws: GitCleanupFailure.expired) { try cancelled.consume() }
    }

    @Test("Executor initialization, discard and unknown IDs perform no filesystem work")
    func inertExecutor() async throws {
        let parent = try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)
        let absent = parent.appendingPathComponent("MoeKit-Git-Inert-\(UUID().uuidString)")
        let executor = NativeGitCleanupExecutor(catalogDirectory: absent)
        await executor.discard()
        await #expect(throws: GitCleanupFailure.expired) { try await executor.execute(UUID(), permit: GitCleanupPermit()) }
        await #expect(throws: GitCleanupFailure.expired) { try await executor.restore(UUID(), permit: GitCleanupPermit()) }
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }

    @MainActor @Test("An idle store cannot mutate or restore without a prepared result")
    func inertStore() throws {
        let parent = try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)
        let absent = parent.appendingPathComponent("MoeKit-Git-Store-Inert-\(UUID().uuidString)")
        let store = GitCleanupStore(executor: NativeGitCleanupExecutor(catalogDirectory: absent))
        store.confirm(); store.restore(); store.invalidate()
        #expect(store.plan == nil && store.receipt == nil)
        #expect(!store.isBusy && !store.isMutating)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }
}

/// Every command below targets only this newly created synthetic repository.
/// No inherited environment, user config, templates, credentials or network is used.
/// Trusted production mutation ancestry deliberately rejects world-writable /tmp.
struct GitCleanupNativeFixture: Sendable {
    let root: URL
    let main: URL
    let worktree: URL
    let common: URL
    let registration: URL
    let catalog: URL
    let home: URL
    let linked: Bool
    let rootIdentity: InstallerFileSnapshot
    let projectID = UUID()
    let mainID = UUID()
    let marker = Data("MoeKit synthetic tracked fixture\n".utf8)

    init(linked: Bool = true) throws {
        try #require(geteuid() != 0)
        let parent = try MoleAnalysisFiles.canonicalURL(FileManager.default.homeDirectoryForCurrentUser)
        root = parent.appendingPathComponent("MoeKit-GitFixture-\(UUID().uuidString)")
        main = root.appendingPathComponent("main")
        worktree = root.appendingPathComponent("feature")
        common = main.appendingPathComponent(".git")
        registration = common.appendingPathComponent("worktrees/feature")
        catalog = root.appendingPathComponent("catalog")
        home = root.appendingPathComponent("empty-home")
        self.linked = linked
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        rootIdentity = try InstallerDirectoryAnchor.open(root).identity
        do {
            try Data(root.lastPathComponent.utf8).write(to: root.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            for directory in [main, catalog, home, root.appendingPathComponent("empty-template")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try marker.write(to: root.appendingPathComponent("outside-sentinel"), options: .withoutOverwriting)
            try git(["init", "--initial-branch=main", "--template=" + root.appendingPathComponent("empty-template").path], at: main)
            try marker.write(to: main.appendingPathComponent("tracked.txt"), options: .withoutOverwriting)
            try Data("ignored.txt\n".utf8).write(to: main.appendingPathComponent(".gitignore"), options: .withoutOverwriting)
            try git(["add", "--", "tracked.txt", ".gitignore"], at: main)
            try git(["commit", "-m", "Synthetic initial commit"], at: main)
            try git(["branch", "feature"], at: main)
            if linked { try git(["worktree", "add", worktree.path, "feature"], at: main) }
            try saveCatalog(linked ? [mainProject, project] : [mainProject])
        } catch {
            remove()
            throw error
        }
    }

    var project: ProjectRecord {
        .init(id: projectID, name: "Synthetic feature", path: worktree.path, kind: .worktree, branch: "feature",
            gitMetadata: .init(observedAt: Date(timeIntervalSince1970: 0), gitDirectoryPath: registration.path,
                commonDirectoryPath: common.path, isLinkedWorktree: true, isLocked: false))
    }
    var mainProject: ProjectRecord {
        .init(id: mainID, name: "Synthetic main", path: main.path, kind: .repository, branch: "main",
            gitMetadata: .init(observedAt: Date(timeIntervalSince1970: 0), gitDirectoryPath: common.path,
                commonDirectoryPath: common.path, isLinkedWorktree: false, isLocked: false))
    }
    var featureRef: URL { common.appendingPathComponent("refs/heads/feature") }
    func request(_ action: GitCleanupAction = .retireWorktree, branch: String = "feature",
                 scope: URL? = nil, selected: ProjectRecord? = nil, protectedPaths: [String] = []) -> GitCleanupRequest {
        .init(scope: scope ?? root, project: selected ?? (action == .retireWorktree ? project : mainProject),
            baseBranch: "main", branch: branch, action: action, protectedPaths: protectedPaths)
    }
    func executor() -> NativeGitCleanupExecutor { NativeGitCleanupExecutor(catalogDirectory: catalog) }
    func saveCatalog(_ projects: [ProjectRecord]) throws {
        let persistence = CatalogPersistence(directory: catalog)
        _ = try persistence.load()
        try persistence.save(projects)
    }
    func remove() {
        do {
            let anchor = try InstallerDirectoryAnchor.open(root)
            guard rootIdentity.matchesDirectory(try InstallerFileAccess.snapshot(anchor.fd)),
                  try GitCleanupInspection.read(anchor, ".fixture-owner", maximum: 128) == Data(root.lastPathComponent.utf8) else { return }
            try FileManager.default.removeItem(at: root)
        } catch {}
    }
    func assertSentinel() throws {
        #expect(try Data(contentsOf: root.appendingPathComponent("outside-sentinel")) == marker)
        #expect(try Data(contentsOf: main.appendingPathComponent("tracked.txt")) == marker)
    }
    func assertNoRecovery() throws {
        #expect(!FileManager.default.fileExists(atPath: common.appendingPathComponent("moekit-recovery").path))
        #expect(FileManager.default.fileExists(atPath: featureRef.path))
        if linked { #expect(FileManager.default.fileExists(atPath: worktree.path)) }
        try assertSentinel()
    }
    @discardableResult func git(_ arguments: [String], at directory: URL, expectSuccess: Bool = true) throws -> String {
        try #require(directory.pathComponents.starts(with: root.pathComponents))
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
            "-c", "tag.gpgSign=false", "-c", "core.autocrlf=false", "-c", "index.version=2", "-c", "gc.auto=0"] + arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": home.path,
            "XDG_CONFIG_HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_ATTR_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_AUTHOR_NAME": "MoeKit Fixture", "GIT_AUTHOR_EMAIL": "fixture@invalid.example",
            "GIT_COMMITTER_NAME": "MoeKit Fixture", "GIT_COMMITTER_EMAIL": "fixture@invalid.example",
            "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: bytes, as: UTF8.self)
        try #require(process.terminationReason == .exit && (process.terminationStatus == 0) == expectSuccess, "Unexpected fixture Git result: \(text)")
        return text
    }
}

@Suite("Git cleanup native synthetic fixtures", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MOEKIT_GIT_NATIVE_FIXTURE"] == "1"))
struct GitCleanupExecutorTests {
    @Test("Retire actually moves only the linked worktree and registration, preserves the branch, and restores once")
    func retireAndRestore() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let executor = fixture.executor(), originalRef = try Data(contentsOf: fixture.featureRef)
        let originalLink = try Data(contentsOf: fixture.worktree.appendingPathComponent(".git"))
        let plan = try await executor.prepare(fixture.request())
        #expect(plan.targetOID == plan.baseOID)
        #expect(plan.bytes > 0)
        try fixture.assertNoRecovery()
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.registration.path))
        #expect(try Data(contentsOf: fixture.featureRef) == originalRef)
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("worktree/tracked.txt")) == fixture.marker)
        #expect(FileManager.default.fileExists(atPath: plan.recovery.appendingPathComponent("registration/locked").path))
        #expect(FileManager.default.fileExists(atPath: plan.recovery.appendingPathComponent("receipt-completed.json").path))
        try fixture.assertSentinel()
        await #expect(throws: GitCleanupFailure.expired) { try await executor.execute(plan.id, permit: GitCleanupPermit()) }
        try await executor.restore(receipt.id, permit: GitCleanupPermit())
        #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent("tracked.txt")) == fixture.marker)
        #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent(".git")) == originalLink)
        #expect(!FileManager.default.fileExists(atPath: fixture.registration.appendingPathComponent("locked").path))
        #expect(try fixture.git(["status", "--porcelain=v1", "--untracked-files=all", "--ignored"], at: fixture.worktree).isEmpty)
        await #expect(throws: GitCleanupFailure.expired) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
        try fixture.assertSentinel()
    }

    @Test("Delete actually removes a merged local ref, leaves remote-tracking refs and files, and restores it", arguments: ["feature", "topic/feature"])
    func deleteAndRestore(_ branch: String) async throws {
        let fixture = try GitCleanupNativeFixture(linked: false)
        defer { fixture.remove() }
        if branch != "feature" { try fixture.git(["branch", branch], at: fixture.main) }
        try fixture.git(["update-ref", "refs/remotes/origin/feature", "HEAD"], at: fixture.main)
        let ref = fixture.common.appendingPathComponent("refs/heads/" + branch)
        let remote = fixture.common.appendingPathComponent("refs/remotes/origin/feature")
        let original = try Data(contentsOf: ref), originalRemote = try Data(contentsOf: remote)
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request(.deleteBranch, branch: branch))
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        #expect(!FileManager.default.fileExists(atPath: ref.path))
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("branch")) == original)
        #expect(try Data(contentsOf: remote) == originalRemote)
        #expect(!FileManager.default.fileExists(atPath: ref.path + ".lock"))
        try fixture.assertSentinel()
        try await executor.restore(receipt.id, permit: GitCleanupPermit())
        #expect(try Data(contentsOf: ref) == original)
        #expect(try Data(contentsOf: remote) == originalRemote)
        await #expect(throws: GitCleanupFailure.expired) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
    }

    @Test("Another executor, invalidated permits and discarded or superseded plans never mutate")
    func reviewAuthority() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let executor = fixture.executor(), other = fixture.executor()
        let first = try await executor.prepare(fixture.request())
        await #expect(throws: GitCleanupFailure.expired) { try await other.execute(first.id, permit: GitCleanupPermit()) }
        let second = try await executor.prepare(fixture.request())
        await #expect(throws: GitCleanupFailure.expired) { try await executor.execute(first.id, permit: GitCleanupPermit()) }
        let invalidated = GitCleanupPermit(); invalidated.invalidate()
        await #expect(throws: GitCleanupFailure.expired) { try await executor.execute(second.id, permit: invalidated) }
        await #expect(throws: GitCleanupFailure.expired) { try await executor.execute(second.id, permit: GitCleanupPermit()) }
        let third = try await executor.prepare(fixture.request())
        await executor.discard()
        await #expect(throws: GitCleanupFailure.expired) { try await executor.execute(third.id, permit: GitCleanupPermit()) }
        try fixture.assertNoRecovery()
    }

    @Test("Cancellation before execution consumes no filesystem authority")
    func cancelledExecution() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request())
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.execute(plan.id, permit: GitCleanupPermit())
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        try fixture.assertNoRecovery()
    }

    @Test("Modified, staged, untracked, ignored and empty untracked directories protect the worktree", arguments: 0..<5)
    func dirtyWorktrees(_ variant: Int) async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        switch variant {
        case 0: try Data("modified\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.txt"))
        case 1:
            try Data("staged\n".utf8).write(to: fixture.worktree.appendingPathComponent("tracked.txt"))
            try fixture.git(["add", "--", "tracked.txt"], at: fixture.worktree)
        case 2: try Data("untracked\n".utf8).write(to: fixture.worktree.appendingPathComponent("new.txt"))
        case 3: try Data("ignored but valuable\n".utf8).write(to: fixture.worktree.appendingPathComponent("ignored.txt"))
        default: try FileManager.default.createDirectory(at: fixture.worktree.appendingPathComponent("empty-untracked"), withIntermediateDirectories: false)
        }
        await #expect(throws: GitCleanupFailure.dirty) { try await fixture.executor().prepare(fixture.request()) }
        try fixture.assertNoRecovery()
    }

    @Test("A unique commit is protected for both worktree retirement and local branch deletion", arguments: [false, true])
    func uniqueCommits(_ retire: Bool) async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        try fixture.git(["commit", "--allow-empty", "-m", "Synthetic unmerged commit"], at: fixture.worktree)
        if !retire { try fixture.git(["checkout", "--detach"], at: fixture.worktree) }
        await #expect(throws: GitCleanupFailure.uniqueCommits) {
            try await fixture.executor().prepare(fixture.request(retire ? .retireWorktree : .deleteBranch))
        }
        try fixture.assertNoRecovery()
    }

    @Test("Worktree, index and branch locks and in-progress operations refuse preparation", arguments: [
        "worktrees/feature/locked", "worktrees/feature/index.lock", "refs/heads/feature.lock", "index.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD"
    ])
    func gitLocks(_ path: String) async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        try Data("fixture lock\n".utf8).write(to: fixture.common.appendingPathComponent(path), options: .withoutOverwriting)
        await #expect(throws: GitCleanupFailure.locked) { try await fixture.executor().prepare(fixture.request()) }
        try fixture.assertNoRecovery()
    }

    @Test("Main worktrees, checked-out local branches and reserved branches stay protected")
    func protectedMainAndCheckedOutBranches() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        await #expect(throws: (any Error).self) {
            try await fixture.executor().prepare(fixture.request(selected: fixture.mainProject))
        }
        await #expect(throws: GitCleanupFailure.locked) {
            try await fixture.executor().prepare(fixture.request(.deleteBranch))
        }
        for branch in ["main", "master", "develop", "development", "release"] {
            await #expect(throws: GitCleanupFailure.locked) {
                try await fixture.executor().prepare(fixture.request(.deleteBranch, branch: branch))
            }
        }
        try fixture.assertNoRecovery()
    }

    @Test("Scope must contain both repositories and cannot cross another project boundary")
    func crossingScope() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        for scope in [fixture.main, fixture.worktree] {
            await #expect(throws: GitCleanupFailure.scope) { try await fixture.executor().prepare(fixture.request(scope: scope)) }
        }
        for protectedPath in [fixture.worktree.path, fixture.worktree.appendingPathComponent("neighbor").path, fixture.root.path] {
            await #expect(throws: GitCleanupFailure.scope) {
                try await fixture.executor().prepare(fixture.request(protectedPaths: [protectedPath]))
            }
        }
        // An unrelated sibling with a shared string prefix is not an overlap.
        let plan = try await fixture.executor().prepare(fixture.request(protectedPaths: [fixture.worktree.path + "-neighbor"]))
        #expect(plan.request.project.id == fixture.project.id)
        try fixture.assertNoRecovery()
    }

    @Test("Persisted catalog identity and neighboring projects are authoritative")
    func catalogProtection() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        try fixture.saveCatalog([fixture.mainProject])
        await #expect(throws: GitCleanupFailure.changed) { try await fixture.executor().prepare(fixture.request()) }
        let neighbor = ProjectRecord(name: "Protected child", path: fixture.worktree.appendingPathComponent("child").path, kind: .folder)
        try fixture.saveCatalog([fixture.mainProject, fixture.project, neighbor])
        await #expect(throws: GitCleanupFailure.scope) { try await fixture.executor().prepare(fixture.request()) }
        try fixture.assertNoRecovery()
    }

    @Test("Catalog changes after review stop execution before recovery creation")
    func staleCatalog() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request())
        var changed = fixture.project; changed.isPinned = true
        try fixture.saveCatalog([fixture.mainProject, changed])
        await #expect(throws: (any Error).self) { try await executor.execute(plan.id, permit: GitCleanupPermit()) }
        try fixture.assertNoRecovery()
    }

    @Test("Changes to refs, base commits, index identity or clean worktree metadata invalidate review", arguments: 0..<4)
    func staleInspection(_ variant: Int) async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request())
        switch variant {
        case 0:
            let bytes = try Data(contentsOf: fixture.featureRef)
            try bytes.write(to: fixture.featureRef, options: .atomic)
        case 1: try fixture.git(["commit", "--allow-empty", "-m", "Base advanced after review"], at: fixture.main)
        case 2:
            let index = fixture.registration.appendingPathComponent("index")
            try Data(contentsOf: index).write(to: index, options: .atomic)
        default:
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: fixture.worktree.appendingPathComponent("tracked.txt").path)
        }
        await #expect(throws: GitCleanupFailure.changed) { try await executor.execute(plan.id, permit: GitCleanupPermit()) }
        await #expect(throws: GitCleanupFailure.expired) { try await executor.execute(plan.id, permit: GitCleanupPermit()) }
        try fixture.assertNoRecovery()
    }

    @Test("New untracked data after review is never retired")
    func dirtyAfterReview() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request())
        let newFile = fixture.worktree.appendingPathComponent("new-after-review.txt"), bytes = Data("preserve me".utf8)
        try bytes.write(to: newFile, options: .withoutOverwriting)
        await #expect(throws: GitCleanupFailure.dirty) { try await executor.execute(plan.id, permit: GitCleanupPermit()) }
        #expect(try Data(contentsOf: newFile) == bytes)
        try fixture.assertNoRecovery()
    }

    @Test("Linked targets and symlinked tracked files fail without following their targets", arguments: [false, true])
    func symlinkProtection(_ replaceWorktree: Bool) async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        if replaceWorktree {
            let retained = fixture.root.appendingPathComponent("retained-worktree")
            try FileManager.default.moveItem(at: fixture.worktree, to: retained)
            try FileManager.default.createSymbolicLink(at: fixture.worktree, withDestinationURL: retained)
        } else {
            let tracked = fixture.worktree.appendingPathComponent("tracked.txt")
            try FileManager.default.removeItem(at: tracked)
            try FileManager.default.createSymbolicLink(at: tracked, withDestinationURL: fixture.root.appendingPathComponent("outside-sentinel"))
        }
        await #expect(throws: (any Error).self) { try await fixture.executor().prepare(fixture.request()) }
        try fixture.assertNoRecovery()
    }

    @Test("Packed target refs cannot be deleted even when a matching loose ref exists")
    func packedTarget() async throws {
        let fixture = try GitCleanupNativeFixture(linked: false)
        defer { fixture.remove() }
        let ref = try Data(contentsOf: fixture.featureRef)
        try fixture.git(["pack-refs", "--all"], at: fixture.main)
        try ref.write(to: fixture.featureRef, options: .withoutOverwriting)
        await #expect(throws: GitCleanupFailure.unsupported) { try await fixture.executor().prepare(fixture.request(.deleteBranch)) }
        #expect(try Data(contentsOf: fixture.featureRef) == ref)
        try fixture.assertNoRecovery()
    }

    @Test("Unsupported local config is rejected without executing its command")
    func unsupportedConfig() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let config = fixture.common.appendingPathComponent("config")
        var bytes = try Data(contentsOf: config)
        bytes.append(Data("\n[core]\nfsmonitor = /never/execute-this-command\n".utf8))
        try bytes.write(to: config)
        await #expect(throws: GitCleanupFailure.unsupported) { try await fixture.executor().prepare(fixture.request()) }
        #expect(try Data(contentsOf: config) == bytes)
        try fixture.assertNoRecovery()
    }

    @Test("Restoring a retired worktree never overwrites a newly occupied original path")
    func occupiedWorktreeRestore() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request())
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        try FileManager.default.createDirectory(at: fixture.worktree, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let occupant = fixture.worktree.appendingPathComponent("occupant"), bytes = Data("new occupant".utf8)
        try bytes.write(to: occupant, options: .withoutOverwriting)
        await #expect(throws: (any Error).self) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
        #expect(try Data(contentsOf: occupant) == bytes)
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("worktree/tracked.txt")) == fixture.marker)
        #expect(FileManager.default.fileExists(atPath: plan.recovery.appendingPathComponent("registration").path))
        try fixture.assertSentinel()
    }

    @Test("Restoring a deleted branch never overwrites loose or packed replacement refs", arguments: [false, true])
    func occupiedBranchRestore(_ packed: Bool) async throws {
        let fixture = try GitCleanupNativeFixture(linked: false)
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request(.deleteBranch))
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        try fixture.git(["branch", "feature", "main"], at: fixture.main)
        if packed { try fixture.git(["pack-refs", "--all"], at: fixture.main) }
        let occupied = packed ? fixture.common.appendingPathComponent("packed-refs") : fixture.featureRef
        let bytes = try Data(contentsOf: occupied)
        await #expect(throws: (any Error).self) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
        #expect(try Data(contentsOf: occupied) == bytes)
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("branch")) == Data((plan.targetOID + "\n").utf8))
        try fixture.assertSentinel()
    }

    @Test("A failure after the first move retains every worktree byte and the original locked registration")
    func partialWorktreeMove() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let originalRef = try Data(contentsOf: fixture.featureRef)
        let originalLink = try Data(contentsOf: fixture.worktree.appendingPathComponent(".git"))
        let originalIgnore = try Data(contentsOf: fixture.worktree.appendingPathComponent(".gitignore"))
        let executor = NativeGitCleanupExecutor(catalogDirectory: fixture.catalog) { checkpoint in
            if checkpoint == .afterWorktreeMove { throw GitCleanupFailure.changed }
        }
        let plan = try await executor.prepare(fixture.request())
        await #expect(throws: GitCleanupFailure.partial(plan.recovery.path)) {
            try await executor.execute(plan.id, permit: GitCleanupPermit())
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("worktree/tracked.txt")) == fixture.marker)
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("worktree/.git")) == originalLink)
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("worktree/.gitignore")) == originalIgnore)
        #expect(try Data(contentsOf: fixture.featureRef) == originalRef)
        #expect(FileManager.default.fileExists(atPath: fixture.registration.path))
        #expect(try Data(contentsOf: fixture.registration.appendingPathComponent("locked")) == Data(("MoeKit retirement " + plan.id.uuidString + "\n").utf8))
        #expect(!FileManager.default.fileExists(atPath: plan.recovery.appendingPathComponent("registration").path))
        #expect(FileManager.default.fileExists(atPath: plan.recovery.appendingPathComponent("receipt-retained-partial.json").path))
        await #expect(throws: GitCleanupFailure.expired) { try await executor.execute(plan.id, permit: GitCleanupPermit()) }
        await #expect(throws: GitCleanupFailure.expired) { try await executor.restore(plan.id, permit: GitCleanupPermit()) }
        try fixture.assertSentinel()
    }

    @Test("An invalidated restore permit and another executor cannot move a retained branch")
    func restoreAuthority() async throws {
        let fixture = try GitCleanupNativeFixture(linked: false)
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request(.deleteBranch))
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        let invalidated = GitCleanupPermit(); invalidated.invalidate()
        await #expect(throws: GitCleanupFailure.expired) { try await executor.restore(receipt.id, permit: invalidated) }
        await #expect(throws: GitCleanupFailure.expired) { try await fixture.executor().restore(receipt.id, permit: GitCleanupPermit()) }
        #expect(!FileManager.default.fileExists(atPath: fixture.featureRef.path))
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("branch")) == Data((plan.targetOID + "\n").utf8))
        try await executor.restore(receipt.id, permit: GitCleanupPermit())
        #expect(try Data(contentsOf: fixture.featureRef) == Data((plan.targetOID + "\n").utf8))
        try fixture.assertSentinel()
    }

    @Test("A changed recovery payload cannot restore a substituted branch")
    func tamperedReceiptPayload() async throws {
        let fixture = try GitCleanupNativeFixture(linked: false)
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request(.deleteBranch))
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        let payload = plan.recovery.appendingPathComponent("branch"), replacement = Data((String(repeating: "a", count: 40) + "\n").utf8)
        try replacement.write(to: payload, options: .atomic)
        await #expect(throws: GitCleanupFailure.changed) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
        #expect(!FileManager.default.fileExists(atPath: fixture.featureRef.path))
        #expect(try Data(contentsOf: payload) == replacement)
        try fixture.assertSentinel()
    }

    @Test("Worktree restore refuses a moved branch or a branch checked out elsewhere", arguments: [false, true])
    func restoreBranchChanged(_ checkedOut: Bool) async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request())
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        if checkedOut {
            try fixture.git(["worktree", "add", fixture.root.appendingPathComponent("new-feature").path, "feature"], at: fixture.main)
        } else {
            try fixture.git(["commit", "--allow-empty", "-m", "Advance base after retirement"], at: fixture.main)
            try fixture.git(["branch", "--force", "feature", "main"], at: fixture.main)
        }
        await #expect(throws: (any Error).self) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("worktree/tracked.txt")) == fixture.marker)
        #expect(FileManager.default.fileExists(atPath: plan.recovery.appendingPathComponent("registration").path))
        try fixture.assertSentinel()
    }

    @Test("Moving the retained recovery folder into a replacement Git directory does not transfer authority")
    func replacedCommonRestore() async throws {
        let fixture = try GitCleanupNativeFixture(linked: false)
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request(.deleteBranch))
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        let original = fixture.main.appendingPathComponent("old-git")
        try FileManager.default.moveItem(at: fixture.common, to: original)
        try FileManager.default.createDirectory(at: fixture.common, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: original.appendingPathComponent("moekit-recovery"), to: fixture.common.appendingPathComponent("moekit-recovery"))
        await #expect(throws: GitCleanupFailure.changed) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("branch")) == Data((plan.targetOID + "\n").utf8))
        try fixture.assertSentinel()
    }

    @Test("A symlinked packed-refs file blocks branch restore without reading its target")
    func linkedPackedRefsRestore() async throws {
        let fixture = try GitCleanupNativeFixture(linked: false)
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request(.deleteBranch))
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        let sentinel = fixture.root.appendingPathComponent("outside-sentinel")
        try FileManager.default.createSymbolicLink(at: fixture.common.appendingPathComponent("packed-refs"), withDestinationURL: sentinel)
        await #expect(throws: (any Error).self) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
        #expect(!FileManager.default.fileExists(atPath: fixture.featureRef.path))
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("branch")) == Data((plan.targetOID + "\n").utf8))
        try fixture.assertSentinel()
    }

    @Test("Case-aliased symbolic HEADs still protect the selected loose branch")
    func aliasHeadProtection() async throws {
        let fixture = try GitCleanupNativeFixture(linked: false)
        defer { fixture.remove() }
        try Data("ref: refs/heads/Feature\n".utf8).write(to: fixture.common.appendingPathComponent("HEAD"))
        await #expect(throws: GitCleanupFailure.locked) { try await fixture.executor().prepare(fixture.request(.deleteBranch)) }
        try fixture.assertNoRecovery()
    }

    @Test("Branch removal cannot use a selected worktree's obsolete common-directory metadata")
    func staleSelectionTopology() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        try fixture.git(["branch", "unused"], at: fixture.main)
        let ref = fixture.common.appendingPathComponent("refs/heads/unused")
        let before = try Data(contentsOf: ref)
        try Data(("gitdir: " + fixture.root.appendingPathComponent("different/.git/worktrees/feature").path + "\n").utf8).write(to: fixture.worktree.appendingPathComponent(".git"))
        await #expect(throws: GitCleanupFailure.scope) {
            try await fixture.executor().prepare(fixture.request(.deleteBranch, branch: "unused", selected: fixture.project))
        }
        #expect(try Data(contentsOf: ref) == before)
        try fixture.assertNoRecovery()
    }

    @Test("An orphan HEAD using the removed branch name blocks branch restore")
    func orphanRestore() async throws {
        let fixture = try GitCleanupNativeFixture(linked: false)
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request(.deleteBranch))
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        try Data("ref: refs/heads/feature\n".utf8).write(to: fixture.common.appendingPathComponent("HEAD"))
        await #expect(throws: GitCleanupFailure.locked) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
        #expect(!FileManager.default.fileExists(atPath: fixture.featureRef.path))
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("branch")) == Data((plan.targetOID + "\n").utf8))
    }

    @Test("Unknown worktree HEAD state blocks worktree restoration", arguments: [false, true])
    func unknownRestoreHEAD(_ missing: Bool) async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request())
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        let unknown = fixture.common.appendingPathComponent("worktrees/unknown")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if !missing { try Data("malformed HEAD\n".utf8).write(to: unknown.appendingPathComponent("HEAD")) }
        await #expect(throws: GitCleanupFailure.unsupported) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(FileManager.default.fileExists(atPath: plan.recovery.appendingPathComponent("worktree").path))
    }

    @Test("A target-directory replacement at the mutation checkpoint is never captured")
    func replacedWorktreeAtMove() async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let retained = fixture.root.appendingPathComponent("original-feature")
        let replacement = Data("unrelated replacement directory".utf8)
        let executor = NativeGitCleanupExecutor(catalogDirectory: fixture.catalog) { checkpoint in
            if checkpoint == .beforeWorktreeMove {
                try FileManager.default.moveItem(at: fixture.worktree, to: retained)
                try FileManager.default.createDirectory(at: fixture.worktree, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try replacement.write(to: fixture.worktree.appendingPathComponent("neighbor"))
            }
        }
        let plan = try await executor.prepare(fixture.request())
        await #expect(throws: GitCleanupFailure.partial(plan.recovery.path)) { try await executor.execute(plan.id, permit: GitCleanupPermit()) }
        #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent("neighbor")) == replacement)
        #expect(try Data(contentsOf: retained.appendingPathComponent("tracked.txt")) == fixture.marker)
        #expect(!FileManager.default.fileExists(atPath: plan.recovery.appendingPathComponent("worktree").path))
        try fixture.assertSentinel()
    }

    @Test("Only the app-owned temporary parent is canonicalized before strict anchored opening")
    func canonicalSnapshotParent() throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let temporary = fixture.root.appendingPathComponent("private-temp")
        let alias = fixture.root.appendingPathComponent("private-temp-alias")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: temporary)
        // The shared live-path anchor remains strict, including for this alias.
        #expect(throws: (any Error).self) { _ = try InstallerDirectoryAnchor.open(alias) }
        let snapshot = try GitObjectSnapshot(common: InstallerDirectoryAnchor.open(fixture.common), temporaryRoot: alias)
        defer { snapshot.remove() }
        #expect(snapshot.directory.deletingLastPathComponent().path == temporary.path)
        #expect(!snapshot.version.isEmpty)
        try fixture.assertNoRecovery()
    }

    @Test("An ACL-writable temporary parent cannot host executable Git snapshots")
    func unsafeSnapshotParent() throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let temporary = fixture.root.appendingPathComponent("private-temp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let directory = try InstallerDirectoryAnchor.open(temporary)
        let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C::file_inherit,directory_inherit:allow:write\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try #require(acl_set_fd_np(directory.fd, acl, ACL_TYPE_EXTENDED) == 0)
        #expect(throws: (any Error).self) {
            _ = try GitObjectSnapshot(common: InstallerDirectoryAnchor.open(fixture.common), temporaryRoot: temporary)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        try fixture.assertNoRecovery()
    }

    @Test("A cooperating pack-refs cannot republish the target while branch removal holds its locks")
    func packRefsRace() async throws {
        let fixture = try GitCleanupNativeFixture(linked: false)
        defer { fixture.remove() }
        let executor = NativeGitCleanupExecutor(catalogDirectory: fixture.catalog) { checkpoint in
            if checkpoint == .beforeBranchMove {
                _ = try fixture.git(["pack-refs", "--all"], at: fixture.main, expectSuccess: false)
            }
        }
        let plan = try await executor.prepare(fixture.request(.deleteBranch))
        _ = try await executor.execute(plan.id, permit: GitCleanupPermit())
        #expect(!FileManager.default.fileExists(atPath: fixture.featureRef.path))
        if FileManager.default.fileExists(atPath: fixture.common.appendingPathComponent("packed-refs").path) {
            let packed = try Data(contentsOf: fixture.common.appendingPathComponent("packed-refs"))
            #expect(try !GitCleanupInspection.packedContains(packed, branch: "feature"))
        }
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("branch")) == Data((plan.targetOID + "\n").utf8))
        try fixture.assertSentinel()
    }

    @Test("A last-checkpoint ref advance cannot retire or restore stale worktree state", arguments: [false, true])
    func checkpointRefAdvance(_ restore: Bool) async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let tree = try fixture.git(["rev-parse", "main^{tree}"], at: fixture.main).trimmingCharacters(in: .whitespacesAndNewlines)
        let unique = try fixture.git(["commit-tree", tree, "-p", "main", "-m", "Unreferenced checkpoint fixture"], at: fixture.main)
        let executor = NativeGitCleanupExecutor(catalogDirectory: fixture.catalog) { checkpoint in
            if checkpoint == (restore ? .beforeRestoreMove : .beforeWorktreeMove) {
                try Data(unique.utf8).write(to: fixture.featureRef, options: .atomic)
            }
        }
        let plan = try await executor.prepare(fixture.request())
        if restore {
            let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
            await #expect(throws: GitCleanupFailure.changed) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
            #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path))
            #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("worktree/tracked.txt")) == fixture.marker)
        } else {
            await #expect(throws: GitCleanupFailure.partial(plan.recovery.path)) { try await executor.execute(plan.id, permit: GitCleanupPermit()) }
            #expect(try Data(contentsOf: fixture.worktree.appendingPathComponent("tracked.txt")) == fixture.marker)
            #expect(!FileManager.default.fileExists(atPath: plan.recovery.appendingPathComponent("worktree").path))
        }
        #expect(try Data(contentsOf: fixture.featureRef) == Data(unique.utf8))
        try fixture.assertSentinel()
    }

    @Test("ACL write grants added to retained data or its destination block restore", arguments: [false, true])
    func changedRestoreACL(_ destination: Bool) async throws {
        let fixture = try GitCleanupNativeFixture()
        defer { fixture.remove() }
        let executor = fixture.executor(), plan = try await executor.prepare(fixture.request())
        let receipt = try await executor.execute(plan.id, permit: GitCleanupPermit())
        let url = destination ? fixture.root : plan.recovery.appendingPathComponent("worktree/tracked.txt")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0); defer { close(fd) }
        let acl = try #require(acl_from_text("!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:::allow:write\n"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        try #require(acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0)
        await #expect(throws: (any Error).self) { try await executor.restore(receipt.id, permit: GitCleanupPermit()) }
        #expect(!FileManager.default.fileExists(atPath: fixture.worktree.path))
        #expect(try Data(contentsOf: plan.recovery.appendingPathComponent("worktree/tracked.txt")) == fixture.marker)
    }
}
