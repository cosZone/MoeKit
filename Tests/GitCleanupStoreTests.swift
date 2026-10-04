import Foundation
import Testing
@testable import MoeKit

private struct GitStoreCatalogFixture {
    let root: URL
    private let identity: InstallerFileSnapshot
    init() throws {
        let parent = try MoleAnalysisFiles.canonicalURL(FileManager.default.temporaryDirectory)
        root = parent.appendingPathComponent("MoeKit-git-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        identity = try InstallerDirectoryAnchor.open(root).identity
        try Data(root.lastPathComponent.utf8).write(to: root.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
    }
    func remove() {
        do {
            let anchor = try InstallerDirectoryAnchor.open(root)
            guard identity.matchesDirectory(try InstallerFileAccess.snapshot(anchor.fd)),
                  try GitCleanupInspection.read(anchor, ".fixture-owner", maximum: 128) == Data(root.lastPathComponent.utf8) else { return }
            try anchor.validate()
            try FileManager.default.removeItem(at: root)
        } catch {}
    }
}

/// The fixture never reads or mutates a repository. Its gate represents the
/// executor's irreversible move boundary, independently of Task cancellation.
private actor GitStoreFixtureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func pause() async {
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() {
        let waiting = continuation; continuation = nil; waiting?.resume()
    }
}

private actor GitStoreFixtureExecutor: GitCleanupExecuting {
    private var prepared: GitCleanupPlan?
    private var receipt: GitCleanupReceipt?
    private let gate: GitStoreFixtureGate?
    private let pauseBeforeMove: Bool
    private var completionFailure: GitCleanupFailure?
    private(set) var executed: [UUID] = []
    private(set) var restored: [UUID] = []
    private(set) var cancelledAtCompletion: [Bool] = []
    private(set) var pendingPermit: GitCleanupPermit?
    init(gate: GitStoreFixtureGate? = nil, pauseBeforeMove: Bool = false) {
        self.gate = gate; self.pauseBeforeMove = pauseBeforeMove
    }
    func failNextCompletion() { completionFailure = .partial("owned synthetic recovery") }
    private func checkCompletion() throws {
        cancelledAtCompletion.append(Task.isCancelled)
        if let failure = completionFailure { completionFailure = nil; throw failure }
    }
    func prepare(_ request: GitCleanupRequest) -> GitCleanupPlan {
        let plan = GitCleanupPlan(id: UUID(), request: request, commonDirectory: URL(fileURLWithPath: "/Synthetic/main/.git"),
            registration: nil, recovery: URL(fileURLWithPath: "/Synthetic/recovery"), targetOID: String(repeating: "a", count: 40),
            baseOID: String(repeating: "b", count: 40), fingerprint: "owned test display", preparedAt: Date(), bytes: 1,
            gitVersion: "git version 2.39.5 (Apple Git-154)")
        prepared = plan; return plan
    }
    func execute(_ id: UUID, permit: GitCleanupPermit) async throws -> GitCleanupReceipt {
        guard let plan = prepared, plan.id == id else { throw GitCleanupFailure.expired }
        pendingPermit = permit
        if pauseBeforeMove { await gate?.pause() }
        try Task.checkCancellation(); try permit.consume(); prepared = nil; executed.append(id)
        let identity = InstallerFileSnapshot(device: 1, inode: 1, mode: 0, uid: 1, gid: 1, links: 1, flags: 0, bytes: 1,
            modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
        let value = GitCleanupReceipt(id: id, plan: plan, recoveryIdentity: identity, payloadIdentity: identity,
            registrationIdentity: nil, commonIdentity: identity, scopeIdentity: identity,
            destinationParentIdentity: identity, registrationParentIdentity: nil)
        receipt = value
        if !pauseBeforeMove { await gate?.pause() }
        try checkCompletion()
        return value
    }
    func restore(_ id: UUID, permit: GitCleanupPermit) async throws {
        guard receipt?.id == id else { throw GitCleanupFailure.expired }
        pendingPermit = permit
        if pauseBeforeMove { await gate?.pause() }
        try Task.checkCancellation(); try permit.consume(); receipt = nil; restored.append(id)
        if !pauseBeforeMove { await gate?.pause() }
        try checkCompletion()
    }
}

@MainActor @Suite("Git cleanup displayed confirmation identity")
struct GitCleanupStoreTests {
    private var request: GitCleanupRequest {
        .init(scope: URL(fileURLWithPath: "/Synthetic"), project: ProjectRecord(name: "Owned synthetic", path: "/Synthetic/main", kind: .repository),
            baseBranch: "main", branch: "feature", action: .deleteBranch)
    }
    private func wait(_ store: GitCleanupStore) async throws {
        for _ in 0..<10_000 {
            if !store.isBusy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Synthetic store did not finish its in-memory operation")
        throw GitCleanupFailure.expired
    }
    private func wait(_ gate: GitStoreFixtureGate) async throws {
        for _ in 0..<10_000 {
            if await gate.isWaiting { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Synthetic executor did not reach its controlled move boundary")
        throw GitCleanupFailure.expired
    }

    private func retirement(_ project: ProjectRecord, root: URL) -> GitCleanupRequest {
        .init(scope: root, project: project, baseBranch: "main", branch: "feature", action: .retireWorktree)
    }
    @Test("An old displayed plan cannot approve a newer plan with the same branch text")
    func staleDisplay() async throws {
        let executor = GitStoreFixtureExecutor(), store = GitCleanupStore(executor: executor)
        store.inspect(request); try await wait(store)
        let old = try #require(store.plan)
        store.inspect(request); try await wait(store)
        let current = try #require(store.plan)
        #expect(old.id != current.id)
        store.confirm(planID: old.id)
        store.confirm()
        #expect(await executor.executed.isEmpty)
        #expect(store.plan?.id == current.id && !store.isBusy)
        store.confirm(planID: current.id); try await wait(store)
        #expect(await executor.executed == [current.id])
        store.confirm(planID: current.id)
        #expect(await executor.executed == [current.id])
    }
    @Test("Restore confirmation is bound to the displayed receipt, not a later operation")
    func staleRestore() async throws {
        let executor = GitStoreFixtureExecutor(), store = GitCleanupStore(executor: executor)
        store.inspect(request); try await wait(store)
        let first = try #require(store.plan)
        store.confirm(planID: first.id); try await wait(store)
        let displayed = try #require(store.receipt)
        store.inspect(request); try await wait(store)
        let second = try #require(store.plan)
        store.confirm(planID: second.id); try await wait(store)
        store.restore(receiptID: displayed.id)
        store.restore()
        #expect(await executor.restored.isEmpty)
        #expect(store.receipt?.id == second.id)
        store.restore(receiptID: second.id); try await wait(store)
        #expect(await executor.restored == [second.id])
        #expect(store.receipt == nil)
    }
    @Test("Closing or changing context discards displayed confirmation authority")
    func invalidation() async throws {
        let executor = GitStoreFixtureExecutor(), store = GitCleanupStore(executor: executor)
        store.inspect(request); try await wait(store)
        let plan = try #require(store.plan)
        store.invalidate(); store.confirm(planID: plan.id)
        #expect(await executor.executed.isEmpty)
        #expect(store.plan == nil && !store.isBusy)
    }

    @Test("Mutation and restore callbacks cannot cancel their own completed-operation bookkeeping")
    func completionCallbackInvalidation() async throws {
        let executor = GitStoreFixtureExecutor(), store = GitCleanupStore(executor: executor)
        var completions: [Bool] = []
        store.onMutation = { _, restored in
            store.invalidate()
            #expect(!Task.isCancelled)
            #expect(store.isMutating && store.isBusy)
            completions.append(restored)
        }
        store.inspect(request); try await wait(store)
        let plan = try #require(store.plan)
        store.confirm(planID: plan.id); try await wait(store)
        #expect(completions == [false])
        #expect(store.receipt?.id == plan.id && store.plan == nil)
        store.restore(receiptID: plan.id); try await wait(store)
        #expect(completions == [false, true])
        #expect(store.receipt == nil && store.error == nil && !store.isMutating)
        store.onMutation = nil
    }

    @Test("Completed retirement and restore survive project invalidation and persist across workspace reopen")
    func workspaceCatalogRoundTrip() async throws {
        let fixture = try GitStoreCatalogFixture(), root = fixture.root
        defer { fixture.remove() }
        let project = ProjectRecord(name: "Owned worktree", path: root.appendingPathComponent("worktree").path,
            kind: .worktree, branch: "feature", lastOpened: Date(timeIntervalSince1970: 42), isPinned: true)
        let neighbor = ProjectRecord(name: "Owned neighbor", path: root.appendingPathComponent("neighbor").path, kind: .folder)
        let persistence = CatalogPersistence(directory: root)
        try persistence.save([project, neighbor])
        let executor = GitStoreFixtureExecutor(), cleanup = GitCleanupStore(executor: executor)
        let workspace = WorkspaceStore(isDemoEnabled: false, persistence: persistence, gitCleanup: cleanup)
        cleanup.inspect(retirement(project, root: root)); try await wait(cleanup)
        let plan = try #require(cleanup.plan)
        cleanup.confirm(planID: plan.id); try await wait(cleanup)
        #expect(cleanup.receipt?.id == plan.id && cleanup.error == nil)
        #expect(workspace.projects == [neighbor] && workspace.errorMessage == nil)
        #expect(try CatalogPersistence(directory: root).load() == [neighbor])
        let retiredReopen = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        #expect(retiredReopen.projects == [neighbor] && retiredReopen.errorMessage == nil)

        cleanup.restore(receiptID: plan.id); try await wait(cleanup)
        #expect(cleanup.receipt == nil && cleanup.error == nil)
        #expect(workspace.projects == [neighbor, project] && workspace.errorMessage == nil)
        let restoredReopen = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        #expect(restoredReopen.projects == [neighbor, project] && restoredReopen.errorMessage == nil)
        #expect(await executor.executed == [plan.id])
        #expect(await executor.restored == [plan.id])
    }

    @Test("Invalidation after the simulated move keeps real catalog bookkeeping and Demo display separate", arguments: ["context", "demo", "demo-round-trip"])
    func invalidationAfterMove(boundary: String) async throws {
        let fixture = try GitStoreCatalogFixture(), root = fixture.root
        defer { fixture.remove() }
        let project = ProjectRecord(name: "Owned worktree", path: root.appendingPathComponent("worktree").path,
            kind: .worktree, branch: "feature")
        let neighbor = ProjectRecord(name: "Owned neighbor", path: root.appendingPathComponent("neighbor").path, kind: .folder)
        let persistence = CatalogPersistence(directory: root)
        try persistence.save([project, neighbor])
        let gate = GitStoreFixtureGate(), executor = GitStoreFixtureExecutor(gate: gate)
        let cleanup = GitCleanupStore(executor: executor)
        let workspace = WorkspaceStore(isDemoEnabled: false, persistence: persistence, gitCleanup: cleanup)
        cleanup.inspect(retirement(project, root: root)); try await wait(cleanup)
        let plan = try #require(cleanup.plan)

        for restoring in [false, true] {
            workspace.isDemoEnabled = false
            if restoring { cleanup.restore(receiptID: plan.id) }
            else { cleanup.confirm(planID: plan.id) }
            try await wait(gate)
            if boundary == "context" {
                // A catalog edit changes context while the old executor is in
                // flight. Completion must preserve the unrelated newer edit.
                workspace.togglePin(neighbor.id)
            } else {
                workspace.isDemoEnabled = true
                if boundary == "demo-round-trip" { workspace.isDemoEnabled = false }
            }
            #expect(cleanup.isMutating && cleanup.isBusy && cleanup.plan == nil)
            cleanup.inspect(request)
            cleanup.confirm(planID: plan.id)
            cleanup.restore(receiptID: plan.id)
            #expect(cleanup.plan == nil)
            await gate.resume(); try await wait(cleanup)
            #expect(!cleanup.isMutating && cleanup.error == nil && workspace.errorMessage == nil)
            #expect(workspace.projects.contains(where: { $0.id == project.id }) == restoring)
            #expect(cleanup.receipt?.id == (restoring ? nil : plan.id))
            let saved = try CatalogPersistence(directory: root).load()
            #expect(saved == workspace.projects)
            #expect(saved.first(where: { $0.id == neighbor.id })?.isPinned == (boundary == "context" && !restoring))
            if workspace.isDemoEnabled {
                #expect(workspace.displayedProjects == DemoData.projects)
                #expect(workspace.cleanupReviewProject == nil)
            }
            workspace.isDemoEnabled = false
            #expect(workspace.displayedProjects == saved)
        }
        #expect(await executor.executed == [plan.id])
        #expect(await executor.restored == [plan.id])
        #expect(await executor.cancelledAtCompletion == [true, true])
    }

    @Test("Invalidation before the simulated move cancels both mutation and restore authority", arguments: [false, true])
    func invalidationBeforeMove(restoring: Bool) async throws {
        let gate = GitStoreFixtureGate(), executor = GitStoreFixtureExecutor(gate: gate, pauseBeforeMove: true)
        let cleanup = GitCleanupStore(executor: executor)
        var completionCount = 0
        cleanup.onMutation = { _, _ in completionCount += 1 }
        cleanup.inspect(request); try await wait(cleanup)
        let plan = try #require(cleanup.plan)
        cleanup.confirm(planID: plan.id)
        try await wait(gate)
        if restoring {
            await gate.resume(); try await wait(cleanup)
            #expect(completionCount == 1)
            cleanup.restore(receiptID: plan.id)
            try await wait(gate)
        }
        let pendingPermit = try #require(await executor.pendingPermit)
        cleanup.invalidate()
        #expect(throws: GitCleanupFailure.expired) { try pendingPermit.consume() }
        await gate.resume(); try await wait(cleanup)
        #expect(await executor.executed.count == (restoring ? 1 : 0))
        #expect(await executor.restored.isEmpty)
        #expect(completionCount == (restoring ? 1 : 0))
        #expect(cleanup.receipt?.id == (restoring ? plan.id : nil))
        #expect(cleanup.plan == nil && !cleanup.isMutating && cleanup.error != nil)
    }

    @Test("An executor failure after invalidation never reports a completed mutation or rewrites the catalog", arguments: [false, true])
    func failedCompletionAfterInvalidation(restoring: Bool) async throws {
        let fixture = try GitStoreCatalogFixture(), root = fixture.root
        defer { fixture.remove() }
        let project = ProjectRecord(name: "Owned worktree", path: root.appendingPathComponent("worktree").path,
            kind: .worktree, branch: "feature")
        let persistence = CatalogPersistence(directory: root)
        try persistence.save([project])
        let gate = GitStoreFixtureGate(), executor = GitStoreFixtureExecutor(gate: gate)
        let cleanup = GitCleanupStore(executor: executor)
        let workspace = WorkspaceStore(isDemoEnabled: false, persistence: persistence, gitCleanup: cleanup)
        cleanup.inspect(retirement(project, root: root)); try await wait(cleanup)
        let plan = try #require(cleanup.plan)
        cleanup.confirm(planID: plan.id); try await wait(gate)
        if restoring {
            await gate.resume(); try await wait(cleanup)
            cleanup.restore(receiptID: plan.id); try await wait(gate)
        }
        let original = try Data(contentsOf: root.appendingPathComponent("projects.json"))
        let projectsBeforeFailure = workspace.projects
        await executor.failNextCompletion()
        workspace.isDemoEnabled = true
        await gate.resume(); try await wait(cleanup)
        #expect(cleanup.error == GitCleanupFailure.partial("owned synthetic recovery").localizedDescription)
        #expect(cleanup.receipt?.id == (restoring ? plan.id : nil))
        #expect(workspace.projects == projectsBeforeFailure)
        #expect(try Data(contentsOf: root.appendingPathComponent("projects.json")) == original)
        #expect(workspace.displayedProjects == DemoData.projects && workspace.cleanupReviewProject == nil)
        #expect(await executor.cancelledAtCompletion.last == true)
    }

    @Test("A completed real move's catalog failure is preserved for real mode without surfacing in Demo")
    func catalogFailureDuringDemo() async throws {
        let fixture = try GitStoreCatalogFixture(), root = fixture.root
        defer { fixture.remove() }
        let project = ProjectRecord(name: "Owned worktree", path: root.appendingPathComponent("worktree").path,
            kind: .worktree, branch: "feature")
        try CatalogPersistence(directory: root).save([project])
        let persistence = CatalogPersistence(directory: root) { throw CatalogPersistence.CatalogError.writerBusy }
        let gate = GitStoreFixtureGate(), executor = GitStoreFixtureExecutor(gate: gate)
        let cleanup = GitCleanupStore(executor: executor)
        let workspace = WorkspaceStore(isDemoEnabled: false, persistence: persistence, gitCleanup: cleanup)
        cleanup.inspect(retirement(project, root: root)); try await wait(cleanup)
        let plan = try #require(cleanup.plan)
        cleanup.confirm(planID: plan.id); try await wait(gate)
        workspace.isDemoEnabled = true
        await gate.resume(); try await wait(cleanup)
        #expect(cleanup.receipt?.id == plan.id && cleanup.error == nil)
        #expect(workspace.projects.isEmpty && workspace.errorMessage == nil)
        #expect(try CatalogPersistence(directory: root).load() == [project])
        #expect(workspace.displayedProjects == DemoData.projects)
        workspace.isDemoEnabled = false
        #expect(workspace.errorMessage == CatalogPersistence.CatalogError.writerBusy.errorDescription)
    }
}
