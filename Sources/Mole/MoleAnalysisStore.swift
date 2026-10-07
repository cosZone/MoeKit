import Foundation
import Observation

/// Session-only state machine; no startup scanning or execution without the
/// specific, still-current confirmation plan. Cancellation holds ownership.
@MainActor @Observable
final class MoleAnalysisStore {
    let upgradeTerminal: MoleUpgradeTerminalStore
    private(set) var isVerifyingHomebrewInstallation = false {
        didSet { UpdateInstallationSafety.shared.changed(self) }
    }
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
    @ObservationIgnored private let homebrewVerifier: any MoleHomebrewVerifying
    @ObservationIgnored private let discovery: any MoleInstallationDiscovering
    @ObservationIgnored private let executor: any MoleAnalysisExecuting
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(executor: any MoleAnalysisExecuting = MoleAnalysisExecutor(),
         discovery: any MoleInstallationDiscovering = MoleInstallationDiscovery(),
         homebrewVerifier: any MoleHomebrewVerifying = MoleHomebrewVerifier(),
         upgradeTerminal: MoleUpgradeTerminalStore? = nil) {
        self.executor = executor; self.discovery = discovery; self.homebrewVerifier = homebrewVerifier
        self.upgradeTerminal = upgradeTerminal ?? MoleUpgradeTerminalStore()
        self.upgradeTerminal.onSettled = { [weak self] in
            guard let self, !self.isDemoEnabled else { return }
            self.discoverInstalledAnalyzer()
        }
    }
    var isBusy: Bool { isDiscovering || isVerifyingHomebrewInstallation || isPreparing || isRunning || isCancelling || upgradeTerminal.isBusy }
    var canVerifyHomebrewInstallation: Bool { !isBusy && !isDemoEnabled && installation?.selectedCandidate?.canVerifyHomebrew == true }
    var canReviewUpgrade: Bool { !isBusy && !isDemoEnabled && installation?.selectedCandidate?.canUpgradeHomebrew == true }

    func reviewUpgrade() {
        guard canReviewUpgrade, let candidate = installation?.selectedCandidate,
              case .homebrew(let prefix) = candidate.origin,
              let source = MoleUpgradeSource(prefix: prefix) else { return }
        invalidateSelection(); executable = nil
        upgradeTerminal.prepare(source: source, currentVersion: candidate.currentVersion,
                                recommendedVersion: MoleAnalyzerRelease.latestTestedVersion)
    }
    func closeUpgradeReview() {
        guard !upgradeTerminal.isBusy, !isDemoEnabled else { return }
        discoverInstalledAnalyzer()
    }
    func verifyHomebrewInstallation() {
        guard canVerifyHomebrewInstallation, let candidate = installation?.selectedCandidate,
              let observation = candidate.observation, let kegVersion = candidate.kegVersion else { return }
        invalidateSelection(); executable = nil
        let request = generation
        isVerifyingHomebrewInstallation = true
        task = Task { [weak self, homebrewVerifier, discovery] in
            do {
                let evidence = try await homebrewVerifier.verify(expectedVersion: kegVersion,
                    architecture: MoleAnalyzerRelease.nativeArchitecture,
                    installedByteCount: observation.byteCount, installedSHA256: observation.sha256)
                try Task.checkCancellation()
                let fresh = try await discovery.discover()
                guard let current = fresh.selectedCandidate, current.path == candidate.path,
                      current.observation == observation, current.kegVersion == kegVersion,
                      current.isHomebrewCore else { throw MoleAnalysisFailure.changedSelection }
                let version = String(evidence.version.split(separator: "_")[0])
                let release = MoleAnalyzerRelease(version: "V" + version, architecture: evidence.architecture,
                    byteCount: evidence.byteCount, sha256: evidence.sha256, origin: .verifiedHomebrewBottle,
                    onlineProof: MoleOnlineArtifactProof(verifiedAt: evidence.checkedAt,
                        bottleSHA256: evidence.bottleSHA256, bottleURL: evidence.sourceURL))
                guard release.isEligible else { throw MoleAnalysisFailure.unsupportedBinary }
                let issue: MoleInstallationIssue? = release.requiresUntestedConsent ? .untestedVersion : nil
                let verified = MoleInstallationCandidate(path: current.path,
                    state: release.requiresUntestedConsent ? .unverified : .usable, source: current.source,
                    explanation: issue?.explanation ?? String(localized: "The analyzer matches a tested official build. It will be verified again before analysis."),
                    declaredVersion: current.declaredVersion, verifiedRelease: release, origin: current.origin,
                    issue: issue, observation: current.observation, kegVersion: current.kegVersion, isHomebrewCore: true)
                guard let self else { return }
                if self.generation == request, !self.isDemoEnabled {
                    self.installation = MoleInstallationReport(candidates: fresh.candidates.map { $0.path == current.path ? verified : $0 }, inspectedAt: Date())
                    self.executable = URL(fileURLWithPath: verified.path)
                }
                self.finish()
            } catch {
                guard let self else { return }
                if self.generation == request, !self.isDemoEnabled {
                    self.errorMessage = error.localizedDescription
                    if (error as? MoleHomebrewVerificationFailure) == .installedBytesMismatch, let report = self.installation {
                        let changed = MoleInstallationCandidate(path: candidate.path, state: .unverified, source: candidate.source,
                            explanation: MoleInstallationIssue.modifiedBuild.explanation, declaredVersion: candidate.declaredVersion,
                            origin: candidate.origin, issue: .modifiedBuild, observation: candidate.observation,
                            kegVersion: candidate.kegVersion, isHomebrewCore: candidate.isHomebrewCore)
                        self.installation = MoleInstallationReport(candidates: report.candidates.map { $0.path == candidate.path ? changed : $0 }, inspectedAt: Date())
                    }
                }
                self.finish()
            }
        }
    }

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
        let artifact = installation?.selectedCandidate?.verifiedRelease
        task = Task { [weak self, executor] in
            do {
                let plan = try await executor.prepare(executable: executable, directory: directory, verifiedArtifact: artifact)
                try Task.checkCancellation()
                guard let self else { return }
                if self.generation == request, !self.isDemoEnabled { self.plan = plan }
                self.finish()
            } catch { self?.fail(error, request: request) }
        }
    }
    func dismissPlan() { guard !isBusy else { return }; plan = nil }

    func confirm(planID: UUID, acknowledgeUntestedBuild: Bool = false) {
        guard !isBusy, !isDemoEnabled, let plan, plan.id == planID else { return }
        guard !plan.release.requiresUntestedConsent || acknowledgeUntestedBuild else {
            errorMessage = MoleAnalysisFailure.untestedConsentRequired.errorDescription; return
        }
        let request = UUID(); generation = request
        self.plan = nil; result = nil; liveResultID = nil; errorMessage = nil; isRunning = true
        onContextChange?()
        task = Task { [weak self, executor] in
            do {
                let result = try await executor.run(plan, acknowledgeUntestedBuild: acknowledgeUntestedBuild)
                try Task.checkCancellation()
                guard let self else { return }
                if self.generation == request, !self.isDemoEnabled {
                    self.result = result; self.liveResultID = result.release.isReviewed ? UUID() : nil; self.onContextChange?()
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
        isDemoEnabled = enabled; upgradeTerminal.setDemoEnabled(enabled); cancel(); installation = nil; executable = nil; directory = nil; result = nil; errorMessage = nil
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
    private func finish() { task = nil; isDiscovering = false; isVerifyingHomebrewInstallation = false; isPreparing = false; isRunning = false; isCancelling = false }
}
