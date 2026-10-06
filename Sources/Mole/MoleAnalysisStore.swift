import Foundation
import Observation

/// Session-only state machine; no startup scanning or execution without the
/// specific, still-current confirmation plan. Cancellation holds ownership.
@MainActor @Observable
final class MoleAnalysisStore {
    private(set) var installation: MoleInstallationReport?
    private(set) var isDiscovering = false {
        didSet { UpdateInstallationSafety.shared.changed(self) }
    }
    private(set) var executable: URL?
    private(set) var directory: URL?
    private(set) var plan: MoleAnalysisPlan?
    private(set) var result: MoleAnalysisResult?
    private(set) var liveResultID: UUID?
    @ObservationIgnored var onContextChange: (@MainActor () -> Void)?
    private(set) var errorMessage: String?
    private(set) var isPreparing = false {
        didSet { UpdateInstallationSafety.shared.changed(self) }
    }
    private(set) var isRunning = false {
        didSet { UpdateInstallationSafety.shared.changed(self) }
    }
    private(set) var isCancelling = false {
        didSet { UpdateInstallationSafety.shared.changed(self) }
    }
    private(set) var isDemoEnabled = false
    @ObservationIgnored private let discovery: any MoleInstallationDiscovering
    @ObservationIgnored private let executor: any MoleAnalysisExecuting
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(executor: any MoleAnalysisExecuting = MoleAnalysisExecutor(),
         discovery: any MoleInstallationDiscovering = MoleInstallationDiscovery()) {
        self.executor = executor; self.discovery = discovery
    }
    var isBusy: Bool { isDiscovering || isPreparing || isRunning || isCancelling }

    /// Called only when the user opens analysis. App initialization and Demo
    /// never inspect the installation or any selected folder.
    func discoverIfNeeded() {
        guard installation == nil, executable == nil else { return }
        discoverInstalledAnalyzer()
    }
    func discoverInstalledAnalyzer() {
        guard !isBusy, !isDemoEnabled else { return }
        invalidateSelection(); executable = nil; installation = nil
        let request = generation
        isDiscovering = true
        task = Task { [weak self, discovery] in
            do {
                let report = try await discovery.discover()
                try Task.checkCancellation()
                guard let self else { return }
                if self.generation == request, !self.isDemoEnabled {
                    self.installation = report
                    self.executable = report.verifiedExecutable
                }
                self.finish()
            } catch { self?.fail(error, request: request) }
        }
    }
    var canPrepare: Bool { executable != nil && directory != nil && !isBusy && !isDemoEnabled }

    func selectionTicket() -> UUID? { !isBusy && !isDemoEnabled ? generation : nil }
    func selectExecutable(_ url: URL, ticket: UUID) {
        guard !isBusy, !isDemoEnabled, ticket == generation else { return }
        installation = nil; executable = url; invalidateSelection()
    }
    func selectDirectory(_ url: URL, ticket: UUID) {
        guard !isBusy, !isDemoEnabled, ticket == generation else { return }
        directory = url; invalidateSelection()
    }
    private func invalidateSelection() {
        generation = UUID(); plan = nil; result = nil; liveResultID = nil; errorMessage = nil
        onContextChange?()
    }
    func prepare() {
        guard canPrepare, let executable, let directory else { return }
        let request = UUID(); generation = request
        plan = nil; result = nil; liveResultID = nil; errorMessage = nil; isPreparing = true
        onContextChange?()
        task = Task { [weak self, executor] in
            do {
                let plan = try await executor.prepare(executable: executable, directory: directory)
                try Task.checkCancellation()
                guard let self else { return }
                if self.generation == request, !self.isDemoEnabled { self.plan = plan }
                self.finish()
            } catch { self?.fail(error, request: request) }
        }
    }
    func dismissPlan() { guard !isBusy else { return }; plan = nil }

    func confirm(planID: UUID) {
        guard !isBusy, !isDemoEnabled, let plan, plan.id == planID else { return }
        let request = UUID(); generation = request
        self.plan = nil; result = nil; liveResultID = nil; errorMessage = nil; isRunning = true
        onContextChange?()
        task = Task { [weak self, executor] in
            do {
                let result = try await executor.run(plan)
                try Task.checkCancellation()
                guard let self else { return }
                if self.generation == request, !self.isDemoEnabled {
                    self.result = result; self.liveResultID = UUID(); self.onContextChange?()
                }
                self.finish()
            } catch { self?.fail(error, request: request) }
        }
    }
    func cancel() {
        plan = nil; result = nil; liveResultID = nil; generation = UUID()
        onContextChange?()
        guard task != nil else { return }
        generation = UUID(); isCancelling = true
        task?.cancel()
    }
    /// An imported report is a separate read-only context and invalidates any
    /// earlier live-result selection authority, even if its paths are identical.
    func invalidateLiveResult() { cancel() }

    func setDemoEnabled(_ enabled: Bool) {
        guard enabled != isDemoEnabled else { return }
        isDemoEnabled = enabled; cancel(); installation = nil; executable = nil; directory = nil; result = nil; errorMessage = nil
    }
    private func fail(_ error: any Error, request: UUID) {
        if generation == request, !isDemoEnabled {
            errorMessage = isDiscovering ? String(localized: "The installation check did not finish. Recheck to try again. No tool was run.") : (error as? MoleAnalysisFailure)?.errorDescription ??
                String(localized: "The analysis could not finish. No new report was accepted.")
        } else if isCancelling, !isDemoEnabled {
            errorMessage = (error as? MoleAnalysisFailure) == .cleanupIncomplete ?
                MoleAnalysisFailure.cleanupIncomplete.errorDescription : MoleAnalysisFailure.cancelled.errorDescription
        }
        finish()
    }
    private func finish() { task = nil; isDiscovering = false; isPreparing = false; isRunning = false; isCancelling = false }
}
