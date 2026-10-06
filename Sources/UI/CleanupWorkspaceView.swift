import AppKit
import SwiftUI

/// A separately scoped native workflow. Mole reports never supply authority.
@MainActor
struct CleanupWorkspaceView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var suppliedStore: CleanupStore?
    private var store: CleanupStore { suppliedStore ?? workspace.cleanup }

    init(store: CleanupStore? = nil) { _suppliedStore = State(initialValue: store) }

    private var workspaceContext: CleanupWorkspaceContext {
        Self.context(workspace)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Native cache cleanup", systemImage: "trash").fontWeight(.medium)
                    .installerCaptureIdentity("cleanup.heading", text: String(localized: "Native cache cleanup"))
                Spacer()
                Text("Explicit selection · native macOS Trash").foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(height: 38)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    introduction
                    folderSelection
                    if store.isBusy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(store.isCancelling ? "Waiting for the actual cleanup outcome…" : "Checking the selected cleanup operation…")
                            Spacer()
                            Button("Cancel") { store.cancel() }.disabled(store.isCancelling)
                        }
                        Text("Cancel stops before the next mutation when possible. A started native operation may finish; its actual per-item outcomes and recovery records remain available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = store.errorMessage { warning(error) }
                    if let inspection = store.inspection { candidates(inspection) }
                    if let plan = store.plan { trashConfirmation(plan) }
                    if let plan = store.recoveryPlan { recoveryConfirmation(plan) }
                    if let outcome = store.lastOutcome { outcomes(outcome) }
                    if let error = store.lastMutationError { warning(error) }
                    recovery
                }.padding(20)
            }
            StatusBar(leading: String(localized: "Logical sizes are not a physical-space recovery estimate"), trailing: "MoeKit · Native")
        }
        .onAppear {
            store.bindContext { [weak workspace] in
                guard let workspace else { return .init(isDemoEnabled: true, modeGeneration: UUID(), protectedPaths: [], catalogIsKnown: false) }
                return Self.context(workspace)
            }
            store.onMutationOutcome = { [weak workspace] in workspace?.moleAnalysis.invalidateLiveResult() }
        }
        .onChange(of: workspaceContext) { _, value in store.updateContext(value) }
        .onDisappear { store.cancel() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review caches before changing files").font(.title2.weight(.semibold))
            Text("Choose your user cache folder, or a folder containing directories with a valid CACHEDIR.TAG. Only eligible direct-child directories are offered. A cache name or marker does not prove the contents are disposable.")
            Text("Git projects, worktrees and unverified build artifacts are protected. No Mole cleanup command, package removal, project deletion or broad Trash emptying runs here.")
                .font(.caption).foregroundStyle(.secondary)
            if store.isDemoEnabled {
                Label("Native cleanup is unavailable in Demo. Actual operation receipts from this session remain visible.", systemImage: "lock")
                    .foregroundStyle(.secondary)
            } else if !store.catalogIsKnown {
                Label("A readable project catalog is required before cleanup can be reviewed.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var folderSelection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Choose a folder and inspect").font(.headline)
                Text("Choosing a folder does not scan it. Inspect reads a bounded, complete inventory without following symbolic links or changing cache contents.")
                    .font(.caption).foregroundStyle(.secondary)
                if let root = store.rootURL { path("Selected folder", root) }
                else { Text("No folder selected").foregroundStyle(.secondary) }
                HStack {
                    Button("Choose user caches") { chooseUserCaches() }
                    Button("Choose folder containing caches…") { chooseFolder() }
                    Spacer()
                    Button("Inspect selected folder") { store.inspect() }.disabled(!store.canInspect)
                }.disabled(store.isBusy || store.isDemoEnabled)
            }.padding(6)
        }
    }

    private func candidates(_ inspection: CleanupInspection) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("2. Select caches to review").font(.headline)
                Text(inspection.observedAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                if inspection.candidates.isEmpty {
                    Text("No eligible cache candidates were found in this folder. This does not prove the folder is empty.")
                        .foregroundStyle(.secondary)
                } else {
                    Table(inspection.candidates, selection: Binding<Set<String>>(
                        get: { store.selectedPaths }, set: { store.select(paths: $0) }
                    )) {
                        TableColumn("Cache") { candidate in
                            Text(InstallerPathDisplay.quoted(candidate.url.lastPathComponent))
                                .lineLimit(1).help(InstallerPathDisplay.quoted(candidate.url.path))
                        }.width(min: 130, ideal: 180)
                        TableColumn("Logical size") { candidate in
                            if let manifest = candidate.manifest { Text(size(manifest.logicalBytes)).monospacedDigit() }
                            else { Text("Unknown").foregroundStyle(.secondary) }
                        }.width(min: 100, ideal: 130)
                        TableColumn("Review status") { candidate in
                            Label(candidate.blocker ?? candidate.evidence,
                                  systemImage: candidate.isEligible ? "checklist" : "lock")
                                .foregroundStyle(candidate.isEligible ? Color.secondary : Color.orange)
                                .help(candidate.blocker ?? candidate.evidence)
                        }.width(min: 180, ideal: 300)
                    }
                    .frame(minHeight: 180, idealHeight: 260, maxHeight: 320)
                    .disabled(store.isBusy)
                    .accessibilityLabel("Cache candidates, select one or more eligible rows")
                    ForEach(inspection.candidates.filter { store.selectedPaths.contains($0.id) }) { candidate in
                        path("Selected cache", candidate.url)
                    }
                }
                HStack {
                    Text("\(store.selectedPaths.count) selected").foregroundStyle(.secondary)
                    Spacer()
                    Button("Review selected caches…") { store.prepare() }.disabled(!store.canPrepare)
                }
                Text("Use Command-click or Shift-click to select multiple eligible rows. Blocked rows cannot be selected for cleanup.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }

    private func trashConfirmation(_ plan: CleanupPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("3. Confirm these exact caches").font(.headline)
                    .installerCaptureIdentity("cleanup.trash.heading", text: String(localized: "3. Confirm these exact caches"))
                Text("\(plan.targets.count) caches · \(size(plan.logicalBytes)) of logical content").monospacedDigit()
                Text("MoeKit will recheck and move only these reviewed cache directories to native macOS Trash. Files remain stored in Trash; this step does not free their storage.")
                    .installerCaptureIdentity("cleanup.trash.effects", text: String(localized: "MoeKit will recheck and move only these reviewed cache directories to native macOS Trash. Files remain stored in Trash; this step does not free their storage."))
                ForEach(Array(plan.targets.enumerated()), id: \.offset) { index, target in
                    manifest(target.manifest, root: target.originalURL, idPrefix: "cleanup.trash.target.\(index)")
                    Text(target.evidence).font(.caption).foregroundStyle(.secondary)
                }
                path("Private recovery root", plan.recoveryRoot, id: "cleanup.trash.recovery-path")
                Text("After confirmation, MoeKit may create private parent directories, coordination locks, per-item staging directories and numbered recovery records here. Records disclose these original paths and persist after the operation. Closing this plan creates none of them.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Close apps, builds, sync jobs and other workloads using these caches first. Inventory and identity checks cannot prove global non-use or prevent every same-user race.")
                    .installerCaptureIdentity("cleanup.trash.use-warning", text: String(localized: "Close apps, builds, sync jobs and other workloads using these caches first. Inventory and identity checks cannot prove global non-use or prevent every same-user race."))
                Toggle("I have stopped the apps and workloads using every selected cache", isOn: Binding(
                    get: { store.workloadsStopped }, set: { store.attestWorkloadsStopped($0, planID: plan.id) }
                )).installerCaptureIdentity("cleanup.trash.workload-attestation", text: String(localized: "I have stopped the apps and workloads using every selected cache"))
                Toggle("I reviewed the full paths and can regenerate all selected content", isOn: Binding(
                    get: { store.contentRegenerable }, set: { store.attestContentRegenerable($0, planID: plan.id) }
                )).installerCaptureIdentity("cleanup.trash.content-attestation", text: String(localized: "I reviewed the full paths and can regenerate all selected content"))
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        expiry(plan.expiresAt)
                        HStack {
                            Button("Cancel plan") { store.cancel() }.installerCaptureIdentity("cleanup.trash.cancel", text: String(localized: "Cancel plan"))
                            Spacer()
                            Button("Move selected caches to Trash") { store.confirm(planID: plan.id) }.installerCaptureIdentity("cleanup.trash.confirm", text: String(localized: "Move selected caches to Trash"))
                                .buttonStyle(.borderedProminent).disabled(!store.canConfirm(planID: plan.id))
                        }
                    }
                }
            }.padding(6)
        }
    }

    private func recoveryConfirmation(_ plan: CleanupRecoveryPlan) -> some View {
        let deletes = plan.action == .deletePermanently
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(deletes ? "Confirm permanent deletion of this cache" : "Confirm original-path cache restore")
                    .font(.headline)
                Text("Receipt \(plan.receipt.id.uuidString)").font(.caption.monospaced()).textSelection(.enabled)
                path("Original cache path", plan.receipt.target.originalURL, id: "cleanup.recovery.original-path")
                manifest(plan.receipt.manifest, root: plan.sourceURL, idPrefix: "cleanup.recovery.target")
                path("Private operation records", plan.receipt.operationURL, id: "cleanup.recovery.records")
                if deletes {
                    Text("This permanently deletes only this receipt’s validated cache and the complete contents listed above. It cannot be undone through Trash or MoeKit. Other Trash items are not selected or emptied.")
                    .installerCaptureIdentity("cleanup.recovery.effects", text: String(localized: "This permanently deletes only this receipt’s validated cache and the complete contents listed above. It cannot be undone through Trash or MoeKit. Other Trash items are not selected or emptied."))
                        .foregroundStyle(.red)
                    Text("Logical bytes are not guaranteed physically reclaimed space. Open files, APFS snapshots, clones and filesystem behavior can retain storage.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("I understand this exact cache will be permanently deleted and cannot be restored", isOn: Binding(
                        get: { store.irreversibleDeletionAccepted }, set: { store.attestIrreversibleDeletion($0, planID: plan.id) }
                    )).installerCaptureIdentity("cleanup.recovery.attestation", text: String(localized: "I understand this exact cache will be permanently deleted and cannot be restored"))
                } else {
                    Text("MoeKit will move this exact recorded cache back to its original path after rechecking it. An occupied destination refuses the restore; nothing is overwritten.")
                    .installerCaptureIdentity("cleanup.recovery.effects", text: String(localized: "MoeKit will move this exact recorded cache back to its original path after rechecking it. An occupied destination refuses the restore; nothing is overwritten."))
                }
                Text("This operation appends private recovery records. If interrupted or only partly completed, inspect the per-item outcome and read recovery records before deciding what to do next.")
                    .font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        expiry(plan.expiresAt)
                        HStack {
                            Button("Cancel plan") { store.cancel() }.installerCaptureIdentity("cleanup.recovery.cancel", text: String(localized: "Cancel plan"))
                            Spacer()
                            if deletes {
                                Button("Permanently delete this cache", role: .destructive) { store.confirmRecovery(planID: plan.id) }.installerCaptureIdentity("cleanup.recovery.confirm", text: String(localized: "Permanently delete this cache"))
                                    .disabled(!store.canConfirmRecovery(planID: plan.id))
                            } else {
                                Button("Restore this cache") { store.confirmRecovery(planID: plan.id) }.installerCaptureIdentity("cleanup.recovery.confirm", text: String(localized: "Restore this cache"))
                                    .buttonStyle(.borderedProminent).disabled(!store.canConfirmRecovery(planID: plan.id))
                            }
                        }
                    }
                }
            }.padding(6)
        }
    }

    private func manifest(_ manifest: CleanupManifest, root: URL, idPrefix: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            path("Exact target", root, id: idPrefix + ".root")
            Text("\(manifest.itemCount) inventory entries · \(manifest.logicalBytes) logical bytes").font(.caption).monospacedDigit()
            Text("Complete reviewed path inventory").font(.subheadline.weight(.medium))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(manifest.entries, id: \.relativePath) { entry in
                        let url = entry.relativePath.isEmpty || entry.relativePath == "." ? root : root.appendingPathComponent(entry.relativePath)
                        Label {
                            Text(InstallerPathDisplay.quoted(url.path)).font(.caption.monospaced())
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: entry.kind == .directory ? "folder" : (entry.kind == .symbolicLink ? "link" : "doc"))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.frame(minHeight: 70, maxHeight: 240).background(MoeStyle.secondarySurface)
            if manifest.entries.contains(where: { $0.kind == .symbolicLink }) {
                Label("Symbolic links are included as links only. Their destinations are not followed or included.", systemImage: "link")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func outcomes(_ outcome: CleanupOutcome) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Latest actual per-item outcomes").font(.headline)
                if store.isDemoEnabled { Text("Actual operations from this session, not example data").font(.caption) }
                ForEach(outcome.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        path("Original path", item.originalURL)
                        Label(item.message, systemImage: item.requiresRecovery ? "exclamationmark.triangle" : (item.succeeded ? "checkmark.circle" : "xmark.circle"))
                            .foregroundStyle(item.requiresRecovery ? Color.orange : Color.primary).textSelection(.enabled)
                        if let receipt = item.receipt { path("Operation records", receipt.operationURL) }
                    }
                }
            }.padding(6)
        }
    }

    private var recovery: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Cache recovery receipts").font(.headline)
                    Spacer()
                    Button("Read cache recovery records") { store.loadRecovery() }.disabled(!store.canReadRecovery)
                }
                Text("Explicit read-only listing of MoeKit’s cache receipts. No broad Trash scan or automatic recovery occurs. Restore and permanent deletion each require a fresh review and separate confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.recoveryItems.isEmpty {
                    Text(store.hasReadRecovery ? "No validated cache recovery records found" : "Cache recovery records have not been read")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.recoveryItems) { item in
                    Divider()
                    if let receipt = item.receipt {
                        Text(receiptTitle(receipt.state)).font(.headline)
                        path("Original cache path", receipt.target.originalURL)
                        if let payload = receipt.payloadURL { path("Recorded payload path", payload) }
                        path("Operation records", receipt.operationURL)
                        Text("Receipt \(receipt.id.uuidString) · record \(receipt.sequence)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            if receipt.canRestore {
                                Button("Review cache restore…") { store.prepareRecovery(receiptID: receipt.id, action: .restore) }
                            }
                            if receipt.canDeletePermanently {
                                Button("Review permanent deletion…") { store.prepareRecovery(receiptID: receipt.id, action: .deletePermanently) }
                            }
                        }.disabled(!store.canReadRecovery || !store.catalogIsKnown)
                    } else {
                        warning(item.issue ?? String(localized: "Recovery record unavailable; outcome unknown"))
                            .installerCaptureIdentity("cleanup.unknown.warning", text: item.issue ?? String(localized: "Recovery record unavailable; outcome unknown"))
                        path("Operation records", item.operationURL)
                        Text("Incomplete records cannot authorize restore or deletion. Retained data is preserved.")
                    .installerCaptureIdentity("cleanup.unknown.effects", text: String(localized: "Incomplete records cannot authorize restore or deletion. Retained data is preserved."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(6)
        }
    }

    private func chooseFolder() {
        guard let ticket = store.selectionTicket() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder whose direct-child cache directories you want to inspect.")
        if panel.runModal() == .OK, let url = panel.url { store.selectRoot(url, ticket: ticket) }
    }
    private func chooseUserCaches() {
        guard let ticket = store.selectionTicket(),
              let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        store.selectRoot(url, ticket: ticket)
    }
    private static func context(_ workspace: WorkspaceStore) -> CleanupWorkspaceContext {
        let paths = workspace.projects.flatMap { project -> [String] in
            var result = [project.path]
            if let metadata = project.gitMetadata { result += [metadata.gitDirectoryPath, metadata.commonDirectoryPath] }
            return result
        }
        return CleanupWorkspaceContext(isDemoEnabled: workspace.isDemoEnabled, modeGeneration: workspace.toolPreparation.modeGeneration,
            protectedPaths: Array(Set(paths)).sorted(), catalogIsKnown: workspace.installerTrash.catalogIsKnown)
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func expiry(_ date: Date) -> some View {
        Text("Confirmation expires at \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
    }
    private func path(_ title: LocalizedStringKey, _ value: URL, id: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(InstallerPathDisplay.quoted(value.path)).font(.callout.monospaced()).textSelection(.enabled)
                .installerCaptureIdentity(id, text: InstallerPathDisplay.quoted(value.path))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func warning(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
    }
    private func receiptTitle(_ state: CleanupReceiptState) -> String {
        switch state {
        case .captureIntent, .staged, .trashIntent: String(localized: "Cache Trash operation requires review")
        case .trashed: String(localized: "Cache moved to Trash")
        case .restoreCaptureIntent, .restoreStaged, .restoreIntent: String(localized: "Cache restore requires review")
        case .restored: String(localized: "Cache restored")
        case .deleteCaptureIntent, .deleteStaged, .deleteIntent: String(localized: "Permanent cache deletion interrupted")
        case .deleted: String(localized: "Cache permanently deleted")
        case .retained: String(localized: "Cache retained for recovery")
        case .uncertain: String(localized: "Cache outcome uncertain; review recovery records")
        }
    }
}
