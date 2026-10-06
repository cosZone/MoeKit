import AppKit
import SwiftUI

/// Native Git evidence drives every step; AI completion is not cleanliness or
/// merge evidence. The retirement callback only opens a new review form.
struct GitWorktreeFinishView: View {
    let project: ProjectRecord
    let onBack: () -> Void
    let onRetirementReview: (GitWorktreeFinishResult) -> Void
    @Environment(WorkspaceStore.self) private var workspace
    @State private var scope: URL?
    @State private var targetBranch = "main"
    @State private var stoppedTools = false
    @State private var confirmation = ""
    @State private var wantsRemote = false
    @State private var previousRemoteConsent = false

    private var state: GitWorktreeFinishStore { workspace.gitWorktreeFinish }
    private var isBusy: Bool { state.isBusy || state.remotePush.isBusy }
    private var isMutating: Bool { state.isMutating || state.remotePush.isMutating }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Finish AI worktree", systemImage: "arrow.triangle.merge")
                .font(.title2).fontWeight(.semibold)
                .accessibilityIdentifier("git-finish.heading")
            Text(project.path).font(.caption).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Review commits, integrate them locally, then review retirement separately. An AI completion message does not verify saved files, merged commits or tests.")
                    inspectionSection
                    if state.isBusy {
                        ProgressView(state.isMutating ? String(localized: "Integrating and verifying locally…") : String(localized: "Inspecting local Git state…"))
                            .controlSize(.small)
                        Text("Cancelling stops further checks. A running private query must finish its supervisor timeout and exit checks; closing this view is not immediate termination.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = state.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let plan = state.plan, matches(plan.request) { planSection(plan) }
                    if let result = state.result, matches(result.plan.request) { resultSection(result) }
                    previousOperationSection
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Project tests have not been run by MoeKit")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("git-finish.tests-not-run")
                Spacer()
                Button(isBusy ? String(localized: "Cancel inspection") : String(localized: "Back to Git cleanup")) {
                    state.invalidate(); onBack()
                }.keyboardShortcut(.cancelAction).disabled(isMutating)
                    .accessibilityIdentifier("git-finish.back")
            }
        }
        .padding(24).frame(width: 720, height: 760)
        .onChange(of: project) { _, _ in scope = nil; resetReview() }
        .onChange(of: targetBranch) { _, _ in resetReview() }
        .onChange(of: workspace.isDemoEnabled) { _, _ in state.invalidate(); onBack() }
        .onDisappear { state.invalidate() }
        .interactiveDismissDisabled(isMutating)
    }

    private var inspectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Check source and target").font(.headline)
            TextField("Target local branch", text: $targetBranch)
                .disabled(isBusy || workspace.isDemoEnabled)
                .accessibilityIdentifier("git-finish.target-branch")
            Text("Choose an existing local branch. Its clean main worktree can be updated. Diverged histories and unsupported layouts need Git outside MoeKit.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose shared parent folder…") { chooseScope() }
                    .disabled(isBusy || workspace.isDemoEnabled)
                Text(scope?.path ?? String(localized: "No folder selected"))
                    .font(.caption).textSelection(.enabled)
            }
            Text("Checks the selected folder using a private temporary copy of Git data. No hooks, project scripts or network operations run.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Inspection details") {
                Text("Inspection reads only the selected scope and copies bounded Git objects into an app-owned temporary directory. A verified Apple Git binary inspects that copy. No repository hooks, filters, scripts or network operations run.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.font(.caption).foregroundStyle(.secondary)
            Button("Check integration") {
                guard !workspace.isDemoEnabled, let scope else { return }
                stoppedTools = false; confirmation = ""
                state.inspect(.init(scope: scope, project: project, targetBranch: targetBranch,
                    protectedPaths: workspace.projects.filter { $0.id != project.id && $0.kind != .group }.map(\.path)))
            }.disabled(isBusy || workspace.isDemoEnabled || scope == nil || targetBranch.isEmpty)
                .accessibilityIdentifier("git-finish.inspect")
        }
    }

    private func planSection(_ plan: GitWorktreeFinishPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("2. Review local integration").font(.headline)
            LabeledContent("Source branch", value: plan.sourceBranch)
            LabeledContent("Target local branch", value: plan.request.targetBranch)
            LabeledContent("Source commits not in target", value: String(plan.uniqueCommitCount))
            Text("Source commit: \(plan.sourceOID)").font(.caption).textSelection(.enabled)
            Text("Target commit before integration: \(plan.targetOID)").font(.caption).textSelection(.enabled)
            statusSection("Source worktree state", status: plan.sourceStatus)
            if let worktree = plan.targetWorktree {
                Text("Target worktree: \(worktree.path)").font(.caption).textSelection(.enabled)
                if let status = plan.targetStatus { statusSection("Target worktree state", status: status) }
                else { Label("Target worktree state is unknown", systemImage: "questionmark.circle").foregroundStyle(.orange) }
            } else {
                Text("Target branch is not checked out in a worktree").font(.caption).foregroundStyle(.secondary)
            }
            Text("Untracked and ignored files are counted together. Both stay protected.")
                .font(.caption).foregroundStyle(.secondary)
            Text(plan.gitVersion).font(.caption).foregroundStyle(.secondary)
            Text("Existing commit signatures are preserved; signature trust is not checked.").font(.caption).foregroundStyle(.secondary)
            if !plan.blockers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Resolve before integrating", systemImage: "exclamationmark.triangle")
                        .font(.headline).foregroundStyle(.orange)
                    ForEach(Array(plan.blockers.enumerated()), id: \.offset) { _, blocker in
                        Text(LocalizedStringKey(blocker)).textSelection(.enabled)
                    }
                }.accessibilityIdentifier("git-finish.blockers")
            } else if plan.uniqueCommitCount == 0 {
                Label("All source commits are already in the target. Review retirement separately in Git cleanup.", systemImage: "checkmark.circle")
            }
            if plan.canMerge {
                Text("Fast-forward moves the target branch to the source commit. If checked out in the main worktree, its tracked files and index also change. The source files and branch stay.")
                Text("Recovery: \(plan.recovery.path)").font(.caption).textSelection(.enabled)
                Text("Close tools using both worktrees. Other apps can still write during these checks. Do not edit or run Git until verification finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("I closed terminals, editors and Git operations using both worktrees", isOn: $stoppedTools)
                    .accessibilityIdentifier("git-finish.closed-tools")
                TextField("Type the exact target branch name to confirm", text: $confirmation)
                    .accessibilityIdentifier("git-finish.confirmation-text")
                Text("This confirms local integration only. Retirement needs a separate review and confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Confirm local fast-forward") {
                    guard !workspace.isDemoEnabled, matches(plan.request) else { return }
                    state.confirm(planID: plan.id, targetBranch: confirmation, stoppedTools: stoppedTools)
                    stoppedTools = false; confirmation = ""
                }.disabled(!state.canConfirm(planID: plan.id, targetBranch: confirmation, stoppedTools: stoppedTools)
                    || workspace.isDemoEnabled)
                    .accessibilityIdentifier("git-finish.confirm")
            }
        }
    }

    private func statusSection(_ title: LocalizedStringKey, status: GitFinishStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: status.clean ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.subheadline).fontWeight(.semibold)
                .foregroundStyle(status.clean ? Color.primary : Color.orange)
            LabeledContent("Staged changes", value: status.stagedChanges ? String(localized: "Present") : String(localized: "None"))
            LabeledContent("Modified tracked files", value: String(status.modifiedCount))
            LabeledContent("Untracked or ignored files", value: String(status.untrackedOrIgnoredCount))
            LabeledContent("Extra directories", value: String(status.extraDirectoryCount))
        }.font(.caption)
    }

    private func resultSection(_ result: GitWorktreeFinishResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Label("3. Local integration verified", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
                .accessibilityIdentifier("git-finish.verified")
            Text("The local branch and any updated worktree match the source commit. Project behavior and tests are not verified.")
            Text("Verified commit: \(result.verifiedOID)").font(.caption).textSelection(.enabled)
            Text("Recovery: \(result.recovery.path)").font(.caption).textSelection(.enabled)
            Text("Keep the recovery folder if an operation is interrupted. Local integration has no automatic undo in this view.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Push to a remote branch before retirement", isOn: $wantsRemote)
                .disabled(isBusy || state.remotePush.result != nil)
            if wantsRemote { GitRemotePushView(finish: result, state: state.remotePush) }
            else { Text("Local-only finish selected. No remote push is authorized.").font(.caption).foregroundStyle(.secondary) }
            Text("Review worktree retirement").font(.headline)
            Text("Review again to move the clean worktree into recovery. Its branch stays, and no disk space is freed. A separate confirmation is required.")
            Button("Review retirement…") {
                guard !workspace.isDemoEnabled, !isBusy, state.result?.id == result.id,
                      matches(result.plan.request), !wantsRemote || remoteVerified(for: result) else { return }
                onRetirementReview(result)
            }.disabled(workspace.isDemoEnabled || isBusy || (wantsRemote && !remoteVerified(for: result)))
                .accessibilityIdentifier("git-finish.review-retirement")
        }
    }

    @ViewBuilder private var previousOperationSection: some View {
        if state.result == nil, state.lastOperationRequest?.project == project {
            if let result = state.lastOperationResult {
                Divider()
                Label("Previous local integration completed", systemImage: "clock.arrow.circlepath").font(.headline)
                Text("This is a session record, not a fresh inspection. Inspect the current source and target again before another operation.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Previous target branch", value: result.plan.request.targetBranch)
                Text("Verified commit: \(result.verifiedOID)").font(.caption).textSelection(.enabled)
                Text("Recovery: \(result.recovery.path)").font(.caption).textSelection(.enabled)
                if let remote = state.remotePush.lastResult, remote.plan.request.finish.id == result.id {
                    Text("Last remote destination: \(remote.plan.request.remoteURL)").font(.caption).textSelection(.enabled)
                    Text("Last remote ref: \(remote.plan.remoteRef)").font(.caption).textSelection(.enabled)
                    Text(remote.verified ? String(localized: "The last remote check observed the published commit") : String(localized: "The last remote outcome requires review; no automatic retry was made"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Commit to publish: \(remote.plan.sourceOID)").font(.caption).textSelection(.enabled)
                    if !remote.verified {
                        Toggle("I allow a read-only check of this recorded remote using its existing Keychain credential", isOn: $previousRemoteConsent)
                            .disabled(isBusy)
                        Button("Recheck recorded remote only") {
                            state.remotePush.reconcile(resultID: remote.id, credentialConsent: previousRemoteConsent, allowSessionRecord: true)
                            previousRemoteConsent = false
                        }.disabled(isBusy || !previousRemoteConsent || workspace.isDemoEnabled)
                        if state.remotePush.isBusy { ProgressView("Checking the exact remote branch…").controlSize(.small) }
                        if let error = state.remotePush.error { Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(.orange) }
                    }
                }
            } else if let error = state.lastOperationError, state.error == nil {
                Divider()
                Label("Previous integration needs review", systemImage: "exclamationmark.triangle").font(.headline)
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private func remoteVerified(for result: GitWorktreeFinishResult) -> Bool {
        guard let remote = state.remotePush.result else { return false }
        return remote.verified && remote.plan.request.finish == result
    }

    private func matches(_ request: GitWorktreeFinishRequest) -> Bool {
        request.project == project && request.scope == scope && request.targetBranch == targetBranch
    }

    private func resetReview() {
        state.invalidate(); stoppedTools = false; confirmation = ""; wantsRemote = false
    }

    private func chooseScope() {
        guard !workspace.isDemoEnabled else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Use shared parent")
        panel.message = String(localized: "Choose a parent containing both the main repository and the linked worktree.")
        if panel.runModal() == .OK, let url = panel.url {
            scope = url; resetReview()
        }
    }
}
