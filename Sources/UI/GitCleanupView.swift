import AppKit
import SwiftUI

struct GitCleanupView: View {
    let project: ProjectRecord
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var scope: URL?
    @State private var action = GitCleanupAction.retireWorktree
    @State private var baseBranch = "main"
    @State private var branch = ""
    @State private var stoppedWork = false
    @State private var confirmation = ""
    @State private var restoreTarget: GitCleanupReceipt?
    @State private var isFinishingWorktree = false

    var body: some View {
        if isFinishingWorktree {
            GitWorktreeFinishView(project: project, onBack: { isFinishingWorktree = false }, onRetirementReview: { result in
                // This opens a form only. The cleanup adapter must prepare a
                // fresh retirement plan and obtain its own exact confirmation.
                scope = result.plan.request.scope
                branch = result.plan.sourceBranch
                baseBranch = result.plan.request.targetBranch
                action = .retireWorktree
                stoppedWork = false; confirmation = ""
                workspace.gitCleanup.invalidate()
                isFinishingWorktree = false
            })
        } else { cleanupBody }
    }

    private var cleanupBody: some View {
        let state = workspace.gitCleanup
        VStack(alignment: .leading, spacing: 14) {
            Label("Git cleanup", systemImage: "arrow.triangle.branch").font(.title2).fontWeight(.semibold)
            Text(project.path).font(.caption).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Retire one clean linked worktree, or separately remove one fully merged local branch. Files and refs move into a private recovery folder inside the main repository. This does not reclaim disk space.")
                    if project.kind == .worktree {
                        Button("Finish AI worktree…") {
                            guard !workspace.isDemoEnabled else { return }
                            state.invalidate(); isFinishingWorktree = true
                        }.disabled(state.isBusy || workspace.isDemoEnabled)
                            .accessibilityIdentifier("git-cleanup.finish-worktree")
                    }
                    Picker("Action", selection: $action) {
                        if project.kind == .worktree { Text("Retire linked worktree").tag(GitCleanupAction.retireWorktree) }
                        Text("Delete merged local branch").tag(GitCleanupAction.deleteBranch)
                    }.disabled(state.isBusy)
                    TextField("Local branch", text: $branch).disabled(state.isBusy || action == .retireWorktree)
                    TextField("Keep local base branch", text: $baseBranch).disabled(state.isBusy)
                    Text("The branch must already be contained in this local base. Remote state is not checked or fetched.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Choose shared parent folder…") { chooseScope() }.disabled(state.isBusy)
                        Text(scope?.path ?? "No folder selected").font(.caption).textSelection(.enabled)
                    }
                    Text("Inspection reads only the selected scope and copies bounded Git objects into an app-owned temporary directory. A verified Apple Git binary inspects that copy. No repository hooks, filters, scripts or network operations run.").font(.caption).foregroundStyle(.secondary)
                    Button("Inspect exact target") {
                        guard !workspace.isDemoEnabled, let scope else { return }
                        stoppedWork = false; confirmation = ""
                        state.inspect(.init(scope: scope, project: project, baseBranch: baseBranch, branch: branch, action: action,
                            protectedPaths: workspace.projects.filter { $0.id != project.id && $0.kind != .group }.map(\.path)))
                    }.disabled(state.isBusy || workspace.isDemoEnabled || scope == nil || branch.isEmpty || baseBranch.isEmpty)
                    if state.isBusy {
                        ProgressView("Rechecking exact target…").controlSize(.small)
                        Text("Cancelling stops further checks. A running private query must finish its supervisor timeout and exit checks; closing this view is not immediate termination.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = state.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                    if let plan = state.plan, matchesCurrentSelection(plan) {
                        Divider()
                        Text("Review this exact operation").font(.headline)
                        LabeledContent("Action", value: plan.request.action.title)
                        LabeledContent("Branch", value: plan.request.branch)
                        Text("Commit: " + plan.targetOID).font(.caption).textSelection(.enabled)
                        Text("Exact target: " + plan.request.project.path).font(.caption).textSelection(.enabled)
                        Text(plan.gitVersion).font(.caption).foregroundStyle(.secondary)
                        Text("Kept base: " + plan.request.baseBranch + " · " + plan.baseOID).font(.caption).textSelection(.enabled)
                        Text("Recovery: " + plan.recovery.path).font(.caption).textSelection(.enabled)
                        if plan.request.action == .retireWorktree {
                            Text("The worktree directory and its Git registration will move. The branch stays. Ignored files, untracked files, changes, locks and unsupported layouts block retirement.")
                        } else {
                            Text("Only the named loose local ref will move. The branch must not be checked out anywhere. Its existing configuration and reflog stay for recovery.")
                        }
                        Toggle("I closed terminals, editors and Git operations using this target", isOn: $stoppedWork)
                        Text("This is a fresh bounded check, not an atomic filesystem snapshot or proof that no other program can write. Do not edit or run Git until the operation finishes.").font(.caption).foregroundStyle(.secondary)
                        TextField("Type the exact branch name to confirm", text: $confirmation)
                        Button(plan.request.action.title, role: .destructive) {
                            guard !workspace.isDemoEnabled, matchesCurrentSelection(plan), stoppedWork,
                                  confirmation == plan.request.branch else { return }
                            state.confirm(planID: plan.id); stoppedWork = false; confirmation = ""
                        }.disabled(state.isBusy || !stoppedWork || confirmation != plan.request.branch || workspace.isDemoEnabled)
                    }
                    if let outcome = state.outcome { Label(outcome, systemImage: "checkmark.circle").textSelection(.enabled) }
                    if let receipt = state.receipt {
                        Text("Last operation: " + receipt.plan.request.action.title + " · " + receipt.plan.request.branch).font(.headline)
                        Text("Original target: " + receipt.plan.request.project.path).font(.caption).textSelection(.enabled)
                        Text(receipt.plan.recovery.path).font(.caption).textSelection(.enabled)
                        HStack {
                            Button("Reveal recovery folder") { NSWorkspace.shared.activateFileViewerSelecting([receipt.plan.recovery]) }
                            Button("Review restore…") { restoreTarget = receipt }.disabled(state.isBusy || workspace.isDemoEnabled)
                        }
                        Text("Restore is available in this session. After restarting, keep the recovery folder and its JSON receipts; they record the original paths and commit. No recovery data is automatically purged.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if state.isBusy && state.plan == nil { Text("An in-progress move finishes or retains a recovery record.").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button(state.isBusy ? "Cancel inspection" : "Done") { state.invalidate(); dismiss() }.keyboardShortcut(.cancelAction).disabled(state.isMutating)
            }
        }.padding(24).frame(width: 660, height: 700)
            .onAppear { branch = project.branch ?? ""; if project.kind != .worktree { action = .deleteBranch } }
            .onChange(of: action) { _, _ in state.invalidate(); confirmation = ""; if action == .retireWorktree { branch = project.branch ?? "" } }
            .onChange(of: branch) { _, _ in state.invalidate() }
            .onChange(of: baseBranch) { _, _ in state.invalidate() }
            .onChange(of: workspace.isDemoEnabled) { _, _ in state.invalidate(); dismiss() }
            .onDisappear { state.invalidate() }
            .confirmationDialog("Restore the recorded target to its original location?", isPresented: Binding(
                get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } })) {
                if let target = restoreTarget {
                    Button("Restore without overwrite") {
                        if !workspace.isDemoEnabled { state.restore(receiptID: target.id) }
                        restoreTarget = nil
                    }
                }
                Button("Cancel", role: .cancel) { restoreTarget = nil }
            } message: {
                if let target = restoreTarget {
                    Text("Branch: \(target.plan.request.branch)\nOriginal target: \(target.plan.request.project.path)\nRepository: \(target.plan.commonDirectory.path)\nRecovery: \(target.plan.recovery.path)\n\nClose tools using either location. Existing files, refs and registrations are never overwritten.")
                }
            }
    }
    private func chooseScope() {
        guard !workspace.isDemoEnabled else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use shared parent"; panel.message = "Choose a parent containing both the main repository and the linked worktree."
        if panel.runModal() == .OK, let url = panel.url { scope = url; workspace.gitCleanup.invalidate() }
    }
    private func matchesCurrentSelection(_ plan: GitCleanupPlan) -> Bool {
        plan.request.project == project && plan.request.scope == scope && plan.request.action == action
            && plan.request.branch == branch && plan.request.baseBranch == baseBranch
    }
}
