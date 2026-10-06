import Foundation

/// A local merge result never grants network or credential authority. Remote
/// inspection and the exact push have independent one-use UI confirmations.
actor NativeGitRemotePushExecutor: GitRemotePushExecuting {
    private var prepared: GitRemotePushPlan?
    private var lastAttempt: GitRemotePushPlan?
    private var fingerprint: String?
    private var deadline: TimeInterval?
    private var session: GitRemoteTransportSession?

    func prepare(_ request: GitRemotePushRequest, credentialPermit: GitCleanupPermit) throws -> GitRemotePushPlan {
        discard()
        let endpoint = try GitRemoteEndpoint(request.remoteURL)
        let ref = try GitRemoteEndpoint.ref(branch: request.remoteBranch)
        let evidence = try inspectLocal(request.finish)
        let transport = try GitRemoteTransportSession(common: evidence.common, endpoint: endpoint, ref: ref, sourceOID: request.finish.verifiedOID)
        var retained = false
        defer { if !retained { transport.remove() } }
        try Task.checkCancellation(); try credentialPermit.consume()
        guard let old = try transport.readRemote() else { throw GitRemotePushFailure.missingReference }
        do { try transport.objects.requireAncestor(old, request.finish.verifiedOID) }
        catch { throw GitRemotePushFailure.ancestry }
        try transport.objects.validateSource()
        let again = try inspectLocal(request.finish)
        guard again.fingerprint == evidence.fingerprint else { throw GitRemotePushFailure.changed }
        let plan = GitRemotePushPlan(id: UUID(), request: request, host: endpoint.host, remoteRef: ref,
            sourceOID: request.finish.verifiedOID, expectedRemoteOID: old, preparedAt: Date(), gitVersion: transport.objects.version)
        prepared = plan; fingerprint = evidence.fingerprint; deadline = ProcessInfo.processInfo.systemUptime + 120
        session = transport; retained = true
        return plan
    }

    func push(_ id: UUID, permit: GitCleanupPermit) throws -> GitRemotePushResult {
        guard let plan = prepared, plan.id == id, let fingerprint, let deadline, let session,
              ProcessInfo.processInfo.systemUptime < deadline else { throw GitRemotePushFailure.expired }
        // A plan is one-use, even if a later validation or network step fails.
        prepared = nil; self.fingerprint = nil; self.deadline = nil
        try session.objects.validateSource()
        do { try session.objects.requireAncestor(plan.expectedRemoteOID, plan.sourceOID) }
        catch { throw GitRemotePushFailure.ancestry }
        // Recheck live refs/index/files after the potentially slower ancestry
        // process, immediately before consuming the exact push authority.
        let evidence = try inspectLocal(plan.request.finish)
        guard evidence.fingerprint == fingerprint else { throw GitRemotePushFailure.changed }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw GitRemotePushFailure.expired }
        try Task.checkCancellation(); try permit.consume()
        lastAttempt = plan
        // The compiled pre-push gate checks the push handshake's advertisement,
        // not a racy earlier ls-remote. Normal non-force push and server CAS still
        // apply. No forced refspec, force flag, or force-with-lease is used.
        do { try session.attemptPush(expected: plan.expectedRemoteOID) }
        catch { /* An error cannot prove that the remote rejected the update. */ }
        return observedResult(plan, session: session)
    }

    func reconcile(_ id: UUID, credentialPermit: GitCleanupPermit) throws -> GitRemotePushResult {
        guard let plan = lastAttempt, plan.id == id, let session else { throw GitRemotePushFailure.expired }
        try Task.checkCancellation(); try credentialPermit.consume()
        return observedResult(plan, session: session)
    }

    private func observedResult(_ plan: GitRemotePushPlan, session: GitRemoteTransportSession) -> GitRemotePushResult {
        do {
            let observed = try session.readRemote()
            let state: GitRemotePushState = observed == plan.sourceOID ? .verified :
                observed == plan.expectedRemoteOID ? .notUpdated : .differentOID
            return .init(plan: plan, state: state, observedOID: observed)
        } catch {
            return .init(plan: plan, state: .unknown, observedOID: nil)
        }
    }

    private func inspectLocal(_ result: GitWorktreeFinishResult) throws -> GitWorktreeFinishEvidence {
        guard result.id == result.plan.id, result.verifiedOID == result.plan.sourceOID,
              GitRemoteEndpoint.oid(result.verifiedOID) else { throw GitRemotePushFailure.changed }
        let evidence = try GitWorktreeFinishInspection.inspect(result.plan.request)
        guard evidence.sourceOID == result.verifiedOID, evidence.targetOID == result.verifiedOID,
              evidence.sourceBranch == result.plan.sourceBranch, evidence.sourceStatus.clean,
              evidence.targetStatus?.clean != false else { throw GitRemotePushFailure.changed }
        return evidence
    }

    private func discard() {
        prepared = nil; lastAttempt = nil; fingerprint = nil; deadline = nil
        session?.remove(); session = nil
    }
}
