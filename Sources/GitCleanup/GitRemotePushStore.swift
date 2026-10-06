import Foundation
import Observation

@MainActor @Observable
final class GitRemotePushStore {
    private(set) var plan: GitRemotePushPlan?
    private(set) var result: GitRemotePushResult?
    private(set) var lastResult: GitRemotePushResult?
    private(set) var error: String?
    private(set) var isBusy = false { didSet { UpdateInstallationSafety.shared.changed(self) } }
    private(set) var isMutating = false
    private(set) var isDemoEnabled = false
    @ObservationIgnored private let executor: any GitRemotePushExecuting
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var permit: GitCleanupPermit?

    init(executor: any GitRemotePushExecuting = NativeGitRemotePushExecutor()) { self.executor = executor }
    func setDemoEnabled(_ enabled: Bool) {
        guard isDemoEnabled != enabled else { return }
        isDemoEnabled = enabled; invalidate()
    }
    func invalidate() {
        generation = UUID(); task?.cancel(); task = nil; permit?.invalidate(); permit = nil
        plan = nil; result = nil; error = nil
        if !isMutating { isBusy = false }
    }
    func inspect(_ request: GitRemotePushRequest, credentialConsent: Bool) {
        guard !isDemoEnabled, !isBusy, credentialConsent,
              let endpoint = try? GitRemoteEndpoint(request.remoteURL),
              let remoteRef = try? GitRemoteEndpoint.ref(branch: request.remoteBranch) else { return }
        invalidate(); isBusy = true
        let current = generation, permit = GitCleanupPermit(); self.permit = permit
        task = Task {
            do {
                let value = try await executor.prepare(request, credentialPermit: permit)
                guard generation == current, !Task.isCancelled, !isDemoEnabled else { return }
                guard value.request == request, value.host == endpoint.host, value.remoteRef == remoteRef,
                      value.sourceOID == request.finish.verifiedOID, GitRemoteEndpoint.oid(value.expectedRemoteOID) else { throw GitRemotePushFailure.changed }
                plan = value
            } catch {
                guard generation == current, !Task.isCancelled, !isDemoEnabled else { return }
                self.error = error.localizedDescription
            }
            if generation == current { isBusy = false; task = nil; self.permit = nil }
        }
    }
    func canPush(planID: UUID?, typedRef: String, credentialConsent: Bool) -> Bool {
        guard !isDemoEnabled, !isBusy, credentialConsent, let plan, plan.id == planID,
              typedRef == plan.remoteRef else { return false }
        let age = Date().timeIntervalSince(plan.preparedAt)
        return age >= 0 && age < 120
    }
    func push(planID: UUID?, typedRef: String, credentialConsent: Bool) {
        guard canPush(planID: planID, typedRef: typedRef, credentialConsent: credentialConsent), let plan else { return }
        let current = generation, permit = GitCleanupPermit(); self.permit = permit
        self.plan = nil; result = nil; error = nil; isBusy = true; isMutating = true
        task = Task {
            do {
                let value = try await executor.push(plan.id, permit: permit)
                try accept(value, for: plan)
                lastResult = value
                if generation == current, !isDemoEnabled { result = value }
            } catch {
                if generation == current, !isDemoEnabled { self.error = error.localizedDescription }
            }
            isBusy = false; isMutating = false
            if generation == current { task = nil; self.permit = nil }
        }
    }
    func reconcile(resultID: UUID?, credentialConsent: Bool, allowSessionRecord: Bool = false) {
        guard !isDemoEnabled, !isBusy, credentialConsent, let previous = result ?? (allowSessionRecord ? lastResult : nil),
              previous.id == resultID else { return }
        let current = generation, permit = GitCleanupPermit(); self.permit = permit
        error = nil; isBusy = true
        task = Task {
            do {
                let value = try await executor.reconcile(previous.id, credentialPermit: permit)
                try accept(value, for: previous.plan)
                lastResult = value
                guard generation == current, !Task.isCancelled, !isDemoEnabled else { return }
                result = value
            } catch {
                guard generation == current, !Task.isCancelled, !isDemoEnabled else { return }
                self.error = error.localizedDescription
            }
            if generation == current { isBusy = false; task = nil; self.permit = nil }
        }
    }
    private func accept(_ value: GitRemotePushResult, for plan: GitRemotePushPlan) throws {
        guard value.plan == plan,
              value.state != .verified || value.verified else { throw GitRemotePushFailure.changed }
    }
}

extension GitRemotePushStore: AppUpdateBlocking { var blocksAppUpdate: Bool { isBusy } }
