import SwiftUI

/// Network and credential consent is separate from the local merge approval.
/// No repository-provided remote URL, helper configuration, or hook is executed.
struct GitRemotePushView: View {
    let finish: GitWorktreeFinishResult
    let state: GitRemotePushStore
    @State private var remoteURL = ""
    @State private var remoteBranch = ""
    @State private var credentialConsent = false
    @State private var confirmation = ""
    private var endpoint: GitRemoteEndpoint? { try? GitRemoteEndpoint(remoteURL) }
    private var ref: String? { try? GitRemoteEndpoint.ref(branch: remoteBranch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("4. Review and verify the remote push").font(.headline)
            TextField("Exact HTTPS repository URL", text: $remoteURL)
                .disabled(state.isBusy || state.result != nil)
                .accessibilityIdentifier("git-finish.remote-url")
            TextField("Remote branch name", text: $remoteBranch)
                .disabled(state.isBusy || state.result != nil)
                .accessibilityIdentifier("git-finish.remote-branch")
            Text("Enter a plain HTTPS URL, such as https://github.com/owner/repository.git, and an existing remote branch. Remote configuration from the repository is not used. No fetch, branch creation, force push, or remote deletion is available.")
                .font(.caption).foregroundStyle(.secondary)
            if let endpoint, let ref {
                Text("Credential destination: \(endpoint.host)").font(.caption).textSelection(.enabled)
                Text("Exact remote ref: \(ref)").font(.caption).textSelection(.enabled)
                Toggle("I allow this connection to use existing macOS Keychain Git credentials for this exact host and repository path", isOn: $credentialConsent)
                    .disabled(state.isBusy)
                Text("This may read existing credentials even during inspection. Credentials are not shown or logged; the fixed helper cannot store or erase them. Sign in with your Git client first if access is unavailable. Git may internally use a shell only to dispatch MoeKit's fixed credential helper. Repository hooks are disabled; a fixed native gate checks the approved push target.")
                    .font(.caption).foregroundStyle(.secondary)
                if state.result == nil {
                    Button("Inspect exact remote branch") {
                        guard credentialConsent else { return }
                        confirmation = ""
                        state.inspect(.init(finish: finish, remoteURL: remoteURL, remoteBranch: remoteBranch), credentialConsent: credentialConsent)
                    }.disabled(state.isBusy || !credentialConsent)
                        .accessibilityIdentifier("git-finish.inspect-remote")
                }
            }
            if state.isBusy {
                ProgressView(state.isMutating ? String(localized: "Pushing and independently checking the remote…") : String(localized: "Checking the exact remote branch…"))
                    .controlSize(.small)
            }
            if let error = state.error {
                Label { Text(LocalizedStringKey(error)).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.orange)
            }
            if let plan = state.plan, matches(plan.request) {
                Text("Approved destination: \(plan.request.remoteURL)").font(.caption).textSelection(.enabled)
                Text("Remote ref: \(plan.remoteRef)").font(.caption).textSelection(.enabled)
                Text("Expected remote commit: \(plan.expectedRemoteOID)").font(.caption).textSelection(.enabled)
                Text("Commit to publish: \(plan.sourceOID)").font(.caption).textSelection(.enabled)
                Text("This sends the selected commit and its reachable Git history to the displayed repository using an ordinary non-force push. Confirm only if that repository should receive this code and history.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Type the exact refs/heads/branch to authorize this push", text: $confirmation)
                    .disabled(state.isBusy).accessibilityIdentifier("git-finish.remote-confirmation")
                Button("Confirm exact remote push") {
                    guard matches(plan.request) else { return }
                    state.push(planID: plan.id, typedRef: confirmation, credentialConsent: credentialConsent)
                    confirmation = ""
                }.disabled(!state.canPush(planID: plan.id, typedRef: confirmation, credentialConsent: credentialConsent))
                    .accessibilityIdentifier("git-finish.push")
            }
            if let result = state.result, matches(result.plan.request) {
                outcome(result)
                if !result.verified {
                    Text("The worktree stays available. Do not assume a timeout means the push failed, and do not retry blindly. Check the exact remote again without sending another push.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Recheck remote only") {
                        state.reconcile(resultID: result.id, credentialConsent: credentialConsent)
                    }.disabled(state.isBusy || !credentialConsent)
                        .accessibilityIdentifier("git-finish.reconcile")
                }
            }
            Text("Existing Keychain entries may be host-scoped. The credential is used only for the displayed HTTPS URL; system Keychain access may require your permission.").font(.caption).foregroundStyle(.secondary)
            Text("Remote verification is a fresh observation of the exact ref, not a lock on the server. Remote CI, pull requests, branch protection approvals, and project tests are not checked by this flow.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if remoteBranch.isEmpty { remoteBranch = finish.plan.request.targetBranch } }
        .onChange(of: remoteURL) { _, _ in reset() }
        .onChange(of: remoteBranch) { _, _ in reset() }
        .onDisappear { state.invalidate() }
    }
    @ViewBuilder private func outcome(_ result: GitRemotePushResult) -> some View {
        switch result.state {
        case .verified:
            Label("Remote ref independently verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notUpdated:
            Label("Remote still shows the previous commit", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .differentOID:
            Label("Remote now points to a different commit", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .unknown:
            Label("Remote outcome is unknown", systemImage: "questionmark.circle").foregroundStyle(.orange)
        }
        Text("Remote ref: \(result.plan.remoteRef)").font(.caption).textSelection(.enabled)
        if let observed = result.observedOID { Text("Observed remote commit: \(observed)").font(.caption).textSelection(.enabled) }
    }
    private func matches(_ request: GitRemotePushRequest) -> Bool {
        request.finish == finish && request.remoteURL == remoteURL && request.remoteBranch == remoteBranch
    }
    private func reset() { state.invalidate(); credentialConsent = false; confirmation = "" }
}
