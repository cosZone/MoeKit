import Foundation
import Observation

@MainActor @Observable
final class MoleUpgradeTerminalStore: AppUpdateBlocking {
    enum Phase: Equatable {
        case idle, preparing, ready, running, cancelling
        case finished(OperationTerminalOutcome)
    }
    private(set) var phase = Phase.idle {
        didSet { updateSafety.changed(self) }
    }
    private(set) var plan: MoleUpgradePlan?
    private(set) var transcript = Data()
    private(set) var isDemoEnabled = false
    private(set) var inputRejected = false
    @ObservationIgnored var onSettled: (@MainActor () -> Void)?
    @ObservationIgnored private let updateSafety: UpdateInstallationSafety
    @ObservationIgnored private let executor: any MoleUpgradeExecuting
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var input: OperationTerminalInput?
    @ObservationIgnored private var consumedPlanID: UUID?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var outputFilter = OperationTerminalOutputFilter()
    @ObservationIgnored private var columns = 80
    @ObservationIgnored private var rows = 24
    static let maximumTranscriptBytes = 16 * 1024 * 1024 + 64 * 1024

    init(executor: any MoleUpgradeExecuting = MoleUpgradeExecutor(), updateSafety: UpdateInstallationSafety = .shared) {
        self.executor = executor; self.updateSafety = updateSafety
    }
    deinit { input?.cancel(); task?.cancel() }
    var isReady: Bool { phase == .ready && !isDemoEnabled }
    var isBusy: Bool { phase == .preparing || phase == .running || phase == .cancelling }
    var acceptsInput: Bool { phase == .running && !isDemoEnabled }
    var blocksAppUpdate: Bool { isBusy }
    var outcome: OperationTerminalOutcome? {
        if case .finished(let result) = phase { return result }
        return nil
    }

    /// Call only for an explicit new user review, never on sheet appearance.
    /// Passive dismissal/reopening retains the consumed plan and cannot rerun it.
    func prepare(source: MoleUpgradeSource, currentVersion: String?, recommendedVersion: String) {
        guard !isDemoEnabled else { return }
        switch phase {
        case .idle, .finished: break
        default: return
        }
        generation = UUID(); plan = nil; transcript.removeAll(); inputRejected = false
        outputFilter = OperationTerminalOutputFilter()
        phase = .preparing
        let request = generation
        task = Task { [weak self, executor] in
            do {
                let plan = try await executor.prepare(source: source, currentVersion: currentVersion, recommendedVersion: recommendedVersion)
                try Task.checkCancellation()
                guard let self else { return }
                self.task = nil
                guard self.generation == request, !self.isDemoEnabled else { self.finishCancelled(); return }
                self.plan = plan; self.transcript = Data(plan.reviewText.utf8); self.phase = .ready
            } catch {
                guard let self else { return }
                self.task = nil
                guard self.generation == request, !self.isDemoEnabled else { self.finishCancelled(); return }
                let reason = (error as? LocalizedError)?.errorDescription ?? OperationTerminalFailure.io.errorDescription!
                self.phase = .finished(.notStarted(reason))
            }
        }
    }

    /// Sole launch entrypoint: called only by the focused AppKit keyDown monitor.
    /// Terminal send(), pasted newlines, insertText, ANSI replies and feed() never call it.
    func handleUserReturn(planID: UUID) {
        guard isReady, let plan, plan.id == planID, consumedPlanID != planID else { return }
        consumedPlanID = planID // consume before async work or validation
        let input = OperationTerminalInput()
        input.resize(columns: columns, rows: rows)
        self.input = input; phase = .running
        append(Data(("\r\n" + String(localized: "Executing the reviewed plan…") + "\r\n").utf8))
        let request = generation
        let lease = OperationTerminalLifetime(updateSafety: updateSafety)
        task = Task { [weak self, executor, lease] in
            let outcome = await executor.run(plan, input: input) { [weak self] bytes in
                await self?.receive(bytes, generation: request)
            }
            lease.finish()
            guard let self else { return }
            self.input = nil; self.task = nil
            if self.generation == request, !self.isDemoEnabled {
                self.append(Data(("\r\n" + outcome.message + "\r\n").utf8))
                self.phase = .finished(outcome)
            } else { self.finishCancelled() }
            self.onSettled?()
        }
    }

    func send(_ bytes: Data) {
        guard acceptsInput, let input else { return }
        inputRejected = !input.send(bytes)
    }
    func resize(columns: Int, rows: Int) {
        self.columns = min(1000, max(1, columns)); self.rows = min(1000, max(1, rows))
        input?.resize(columns: self.columns, rows: self.rows)
    }
    func cancel() {
        switch phase {
        case .preparing:
            generation = UUID(); phase = .cancelling; task?.cancel()
        case .ready:
            if let plan { consumedPlanID = plan.id }
            phase = .finished(.notStarted(String(localized: "This review was closed. Nothing was started.")))
        case .running:
            phase = .cancelling; input?.cancel()
        case .idle: phase = .finished(.notStarted(String(localized: "Nothing was started.")))
        case .cancelling, .finished: break
        }
    }
    func setDemoEnabled(_ enabled: Bool) {
        guard enabled != isDemoEnabled else { return }
        isDemoEnabled = enabled; generation = UUID()
        cancel()
        // Never replay a real session into Demo or accept a delayed real result.
        transcript.removeAll(); outputFilter = OperationTerminalOutputFilter()
    }
    private func receive(_ bytes: Data, generation request: UUID) {
        guard generation == request, !isDemoEnabled, phase == .running || phase == .cancelling else { return }
        append(outputFilter.consume(bytes))
    }
    private func append(_ bytes: Data) {
        guard bytes.count <= Self.maximumTranscriptBytes - transcript.count else { input?.cancel(); return }
        transcript.append(bytes)
    }
    private func finishCancelled() { phase = .finished(.cancelled) }
}

/// Independently retained by the running Task, even if the window/store goes
/// away. App replacement stays blocked until native cleanup actually returns.
@MainActor private final class OperationTerminalLifetime: AppUpdateBlocking {
    private let updateSafety: UpdateInstallationSafety
    private(set) var blocksAppUpdate = true
    init(updateSafety: UpdateInstallationSafety) {
        self.updateSafety = updateSafety; updateSafety.changed(self)
    }
    func finish() { blocksAppUpdate = false; updateSafety.changed(self) }
}
