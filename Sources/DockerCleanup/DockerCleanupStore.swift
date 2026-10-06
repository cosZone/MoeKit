import Foundation
import Observation

@MainActor @Observable
final class DockerCleanupStore: AppUpdateBlocking {
    private(set) var endpoint = DockerEndpoint.desktop
    private(set) var inventory: DockerInventory?
    private(set) var selection = DockerSelection()
    private(set) var plan: DockerCleanupPlan?
    private(set) var result: DockerCleanupResult?
    private(set) var errorMessage: String?
    private(set) var isBusy = false { didSet { UpdateInstallationSafety.shared.changed(self) } }
    private(set) var isExecuting = false
    private(set) var isDemoEnabled = false
    var blocksAppUpdate: Bool { isBusy }
    @ObservationIgnored private let executor: any DockerCleanupExecuting
    @ObservationIgnored private var cancellation = DockerCancellation()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var contextProvider: (@MainActor () -> Bool)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var discardTask: Task<Void, Never>?

    /// Inert construction: no daemon connection, filesystem scan or credential/config read.
    init(executor: any DockerCleanupExecuting = NativeDockerCleanupExecutor()) { self.executor = executor }
    var canInspect: Bool { !isDemoEnabled && !isBusy }
    var canPrepare: Bool { canInspect && inventory != nil && !selection.isEmpty }

    func bindContext(_ provider: @escaping @MainActor () -> Bool) {
        contextProvider = provider
        synchronizeContext()
    }
    func updateDemo(_ value: Bool) {
        guard value != isDemoEnabled else { return }
        isDemoEnabled = value
        invalidate(clearInventory: true)
    }
    func chooseEndpoint(_ value: DockerEndpoint) {
        synchronizeContext()
        guard !isBusy, !isDemoEnabled, [DockerEndpoint.desktop, .engine].contains(value), endpoint != value else { return }
        invalidate(clearInventory: true)
        endpoint = value
    }
    func select(_ value: DockerSelection) {
        synchronizeContext()
        guard !isBusy, !isDemoEnabled, let inventory else { return }
        var filtered = value
        filtered.imageIDs.formIntersection(Set(inventory.images.filter(inventory.imageIsEligible).map(\.id)))
        filtered.containerIDs.formIntersection(Set(inventory.containers.filter(\.isStopped).map(\.id)))
        filtered.allUnusedBuildCache = value.allUnusedBuildCache && inventory.buildCache.contains { !$0.inUse }
        selection = filtered
        plan = nil
        discardPlans()
    }
    func inspect() {
        synchronizeContext()
        guard canInspect else { return }
        invalidate(clearInventory: true)
        let expected = generation, endpoint = endpoint, token = begin(), discard = discardTask
        task = Task { [self] in
            defer { finish() }
            do {
                await discard?.value
                let value = try await executor.inspect(endpoint: endpoint, cancellation: token)
                synchronizeContext()
                guard generation == expected, !isDemoEnabled else { return }
                inventory = value
            } catch { report(error, expected: expected) }
        }
    }
    func prepare() {
        synchronizeContext()
        guard canPrepare, let inventory else { return }
        let expected = generation, selection = selection, token = begin(), discard = discardTask
        plan = nil
        task = Task { [self] in
            defer { finish() }
            do {
                await discard?.value
                let value = try await executor.prepare(inventory: inventory, selection: selection, cancellation: token)
                synchronizeContext()
                guard generation == expected, !isDemoEnabled, self.selection == selection else {
                    await executor.discardPlans(); return
                }
                self.inventory = value.inventory
                plan = value
            } catch { report(error, expected: expected) }
        }
    }
    func confirm(planID: UUID) {
        synchronizeContext()
        guard !isBusy, !isDemoEnabled, let approved = plan, approved.id == planID,
              approved.selection == selection, approved.inventory.daemon.endpoint == endpoint else { return }
        plan = nil
        let expected = generation, token = begin()
        isExecuting = true
        task = Task { [self] in
            defer { finish() }
            do {
                let value = try await executor.execute(plan: approved, cancellation: token)
                synchronizeContext()
                guard generation == expected, !isDemoEnabled else { return }
                result = value
                inventory = value.inventory
                selection = DockerSelection()
            } catch {
                // No successful operation result means a new explicit refresh/review is required.
                inventory = nil
                selection = DockerSelection()
                report(error, expected: expected)
            }
        }
    }
    func dismissPlan() {
        plan = nil
        discardPlans()
    }
    func cancel() {
        cancellation.cancel()
        plan = nil
        if !isBusy { discardPlans() }
    }
    func leave() {
        cancel()
        if !isExecuting { invalidate(clearInventory: false) }
    }
    private func synchronizeContext() {
        if let contextProvider { updateDemo(contextProvider()) }
    }
    private func invalidate(clearInventory: Bool) {
        cancellation.cancel()
        generation = UUID()
        plan = nil
        result = nil
        errorMessage = nil
        selection = DockerSelection()
        if clearInventory { inventory = nil }
        discardPlans()
    }
    private func discardPlans() {
        let prior = discardTask, executor = executor
        discardTask = Task { await prior?.value; await executor.discardPlans() }
    }
    private func begin() -> DockerCancellation {
        cancellation = DockerCancellation()
        isBusy = true
        errorMessage = nil
        result = nil
        return cancellation
    }
    private func finish() { isBusy = false; isExecuting = false; task = nil }
    private func report(_ error: any Error, expected: UUID) {
        synchronizeContext()
        guard generation == expected, !isDemoEnabled else { return }
        errorMessage = (error as? LocalizedError)?.errorDescription ?? "Docker operation could not be verified."
        plan = nil
    }
}
