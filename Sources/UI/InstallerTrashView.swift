import SwiftUI

/// Separate native operation UI. This never turns Mole cleanable hints into
/// commands and never exposes arbitrary file picking or batch mutation.
struct InstallerTrashView: View {
    @Environment(WorkspaceStore.self) private var workspace
    private var store: InstallerTrashStore { workspace.installerTrash }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Downloaded disk image", systemImage: "opticaldisc").font(.headline)
                    .accessibilityIdentifier("installer.heading")
                Text("Select one .dmg row from the current live analysis of your local Downloads folder. The report is only a selection hint; MoeKit independently checks the file before offering a confirmation.")
                if !store.isEnabled {
                    Label("Native Trash and restore are disabled in this build pending reviewed macOS fixture tests.", systemImage: "lock")
                        .foregroundStyle(.secondary)
                } else if store.isDemoEnabled {
                    Text("Demo and imported reports cannot authorize native file operations.").foregroundStyle(.secondary)
                } else if !store.catalogIsKnown {
                    Text("A readable project catalog is required before a file operation can be prepared.").foregroundStyle(.orange)
                }
                Text("This version requires a complete, empty disk-image inventory. You may eject images you opened yourself, then check again. Leave system-managed images alone; they can keep this action unavailable. MoeKit does not classify or eject images.")
                    .font(.caption).foregroundStyle(.secondary)
                if let selected = store.selectedPath {
                    path("Selected file", selected)
                    Button("Review native Trash…") { store.prepare() }.disabled(!store.canPrepare)
                } else {
                    Text("No eligible .dmg selected").foregroundStyle(.secondary)
                }
                if store.isBusy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(store.isCancelling ? String(localized: "Waiting for the actual operation outcome…") : String(localized: "Checking the selected operation…"))
                        Spacer()
                        Button("Cancel") { store.cancel() }.disabled(store.isCancelling)
                    }
                    Text("Cancel stops before mutation when possible. If native Trash has started, MoeKit waits for its actual result and keeps the receipt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                }
                if let plan = store.plan { trashConfirmation(plan) }
                if let plan = store.restorePlan { restoreConfirmation(plan) }
                if let outcome = store.lastOutcome {
                    Text("Latest actual operation outcome").font(.headline)
                    Label(outcome.message, systemImage: outcome.requiresRecovery ? "exclamationmark.triangle" : "doc.text")
                        .textSelection(.enabled)
                    if let receipt = outcome.receipt {
                        path("Outcome original path", receipt.originalURL.path)
                        path("Outcome operation records", receipt.operationURL.path)
                    }
                    if store.isDemoEnabled { Text("Actual file-operation receipt from this session").font(.caption).foregroundStyle(.secondary) }
                }
                if let error = store.lastMutationError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                }
                Divider()
                HStack {
                    Text("Recovery receipts").font(.headline)
                    Spacer()
                    Button("Read recovery records") { store.loadRecovery() }.disabled(!store.canReadRecovery)
                        .accessibilityIdentifier("installer.recovery.read")
                }
                Text("Read-only listing of MoeKit’s private records. No Trash scan or automatic restore occurs. Each original-path restore needs a new confirmation and never overwrites a destination.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.recoveryItems.isEmpty {
                    Text(store.hasReadRecovery ? String(localized: "No validated recovery records found") : String(localized: "Recovery records have not been read"))
                        .foregroundStyle(.secondary)
                }
                ForEach(store.recoveryItems) { item in
                    if let receipt = item.receipt {
                        receiptView(receipt)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Divider()
                            Label("Recovery record unavailable; outcome unknown", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).accessibilityIdentifier("installer.recovery.unknown")
                            path("Operation records", item.operationURL.path, id: "installer.recovery.operation-path")
                            if let issue = item.issue { Text(issue).textSelection(.enabled) }
                            Text("No restore is authorized from incomplete or unreadable records. The operation directory and any retained payload are preserved.")
                                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("installer.recovery.effects")
                            Button("Reveal validated recovery location") { store.reveal(receiptID: item.id) }
                                .disabled(!store.canReadRecovery).accessibilityIdentifier("installer.recovery.reveal")
                        }
                    }
                }
            }.padding(6)
        }
    }

    private func trashConfirmation(_ plan: InstallerTrashPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Confirm native macOS Trash").font(.headline).accessibilityIdentifier("installer.trash.heading")
            path("Exact original path", plan.originalURL.path, id: "installer.trash.original-path")
            Text("1 file · \(plan.sizeLabel) (\(plan.file.bytes) bytes)").monospacedDigit()
            Text("MoeKit will move this disk image using native macOS Trash. This is not a Mole cleanup command. Moving to Trash does not free its storage; no Trash emptying is offered here.")
                .accessibilityIdentifier("installer.trash.effects")
            path("Exact private staging path", plan.recoveryURL.appendingPathComponent(plan.originalURL.lastPathComponent).path, id: "installer.trash.staging-path")
            storagePaths(plan.recoveryURL, idPrefix: "installer.trash")
            path("Private journal directory", plan.recoveryURL.path, id: "installer.trash.journal-path")
            path("First recovery record", plan.recoveryURL.appendingPathComponent("000000.json").path, id: "installer.trash.record-path")
            Text("The private MoeKit and InstallerRecovery parent directories and shared operations.lock and projects.json.lock files may also be created. The lock only coordinates cooperating MoeKit instances; it does not lock out other applications.")
                .accessibilityIdentifier("installer.trash.lock-effects")
            Text("After confirmation, MoeKit creates this private operation directory and numbered JSON recovery records inside it. These records persist and disclose the original path only in this private journal. Closing this plan does not create them.")
                .accessibilityIdentifier("installer.trash.journal-effects")
            Text("This version accepts only a complete, empty disk-image inventory. Eject only images you opened yourself. Do not eject system-managed images; an inventory containing them remains unsupported. MoeKit cannot classify images for you and never ejects them.")
                .accessibilityIdentifier("installer.trash.inventory-effects")
            Text("No open descriptor or fileport use observed in the checked current-user processes").font(.headline)
            Text("Checks cover current-user vnode file descriptors and fileports, plus a complete, empty disk-image inventory. Any attached image, including a system-managed image, keeps this operation unavailable; MoeKit does not classify images. Memory mappings, other users, system services and files opened after the check are not exhaustively observable. This is not proof that the image is globally unused.")
                .accessibilityIdentifier("installer.trash.scope-effects")
            Text("A same-user race can temporarily move a replacement before a mismatch is detected. The native Trash API uses a path. This operation is designed for ordinary cooperative local use, not malicious same-user interference.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("I have finished installing and using this disk image", isOn: Binding(
                get: { store.installationFinished },
                set: { store.attestInstallationFinished($0, planID: plan.id) }
            )).accessibilityIdentifier("installer.trash.attestation")
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Confirmation expires at \(plan.expiresAt.formatted(date: .omitted, time: .standard))").font(.caption)
                    HStack {
                        Button("Cancel plan") { store.cancel() }.accessibilityIdentifier("installer.trash.cancel")
                        Spacer()
                        Button("Move this file to Trash") { store.confirm(planID: plan.id) }
                            .buttonStyle(.borderedProminent).disabled(!store.canConfirm(planID: plan.id))
                            .accessibilityIdentifier("installer.trash.confirm")
                    }
                }
            }
        }
    }

    private func restoreConfirmation(_ plan: InstallerRestorePlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Confirm original-path restore").font(.headline).accessibilityIdentifier("installer.restore.heading")
            path("Validated source", plan.sourceURL.path, id: "installer.restore.source-path")
            path("Exact restore destination", plan.receipt.originalURL.path, id: "installer.restore.destination-path")
            Text("1 file · \(ByteCountFormatter.string(fromByteCount: plan.receipt.originalFile.bytes, countStyle: .file)) (\(plan.receipt.originalFile.bytes) bytes)")
            path("Private restore staging path", plan.receipt.operationURL.appendingPathComponent("restore.dmg").path, id: "installer.restore.staging-path")
            storagePaths(plan.receipt.operationURL, idPrefix: "installer.restore")
            path("Private journal directory", plan.receipt.operationURL.path, id: "installer.restore.journal-path")
            path("Next recovery record", plan.receipt.operationURL.appendingPathComponent(String(format: "%06d.json", plan.receipt.sequence + 1)).path, id: "installer.restore.record-path")
            Text("Restore holds the shared operations.lock and projects.json.lock, creating the catalog lock only if missing, and appends numbered JSON records in this operation directory before namespace changes.")
                .accessibilityIdentifier("installer.restore.lock-effects")
            Text("MoeKit will recheck identities and move this exact recorded file back to its original Downloads path. A collision refuses the operation; there is no overwrite or force option. Journal records persist. Finder Put Back may target private staging instead of the original path.")
                .accessibilityIdentifier("installer.restore.effects")
            Text("Restore is unavailable after Trash is emptied, required identities or volumes change, or the original destination is occupied.")
                .font(.caption).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Confirmation expires at \(plan.expiresAt.formatted(date: .omitted, time: .standard))").font(.caption)
                    HStack {
                        Button("Cancel plan") { store.cancel() }.accessibilityIdentifier("installer.restore.cancel")
                        Spacer()
                        Button("Restore to original path") { store.confirmRestore(planID: plan.id) }
                            .buttonStyle(.borderedProminent).disabled(!store.canConfirmRestore(planID: plan.id))
                            .accessibilityIdentifier("installer.restore.confirm")
                    }
                }
            }
        }
    }

    private func receiptView(_ receipt: InstallerTrashReceipt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(receipt.state.title).font(.headline)
            path("Original path", receipt.originalURL.path)
            path("Operation records", receipt.operationURL.path)
            if let trashURL = receipt.trashURL { path("Recorded Trash path", trashURL.path) }
            Text("Receipt \(receipt.id.uuidString) · record \(receipt.sequence)").font(.caption.monospaced()).textSelection(.enabled)
            Text(receipt.recordedAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reveal validated recovery location") { store.reveal(receiptID: receipt.id) }.disabled(!store.canReadRecovery)
                if receipt.canOfferRestore {
                    Button("Review restore…") { store.prepareRestore(receiptID: receipt.id) }
                        .disabled(!store.canReadRecovery || !store.catalogIsKnown)
                }
            }
        }
    }

    private func storagePaths(_ operation: URL, idPrefix: String) -> some View {
        let root = operation.deletingLastPathComponent()
        return VStack(alignment: .leading, spacing: 8) {
            path("Private MoeKit parent directory", root.deletingLastPathComponent().path, id: idPrefix + ".parent-path")
            path("Private recovery root", root.path, id: idPrefix + ".recovery-root-path")
            path("Shared operation lock", root.appendingPathComponent("operations.lock").path, id: idPrefix + ".operation-lock-path")
            path("Shared project-catalog lock", root.deletingLastPathComponent().appendingPathComponent("projects.json.lock").path, id: idPrefix + ".catalog-lock-path")
        }
    }

    private func path(_ title: LocalizedStringKey, _ value: String, id: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(InstallerPathDisplay.quoted(value)).font(.callout.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(id)
                .accessibilityLabel(Text(String(localized: "Full path, escaped: \(InstallerPathDisplay.quoted(value))")))
        }
    }
}

private extension InstallerReceiptState {
    var title: String {
        switch self {
        case .captureIntent: String(localized: "Capture intent recorded; verify recovery location")
        case .captured: String(localized: "File retained in private staging")
        case .trashIntent: String(localized: "Trash intent recorded; outcome needs verification")
        case .trashed: String(localized: "Moved to macOS Trash")
        case .rollbackIntent: String(localized: "Rollback intent recorded; outcome needs verification")
        case .rolledBack: String(localized: "Returned to the original path")
        case .retained: String(localized: "File retained for recovery")
        case .uncertain: String(localized: "Outcome uncertain; review recovery")
        case .restoreCaptureIntent: String(localized: "Restore capture intent recorded; review recovery")
        case .restoreCaptured: String(localized: "Restore payload retained in private staging")
        case .restoreIntent: String(localized: "Restore intent recorded; outcome needs verification")
        case .restored: String(localized: "Restored to the original path")
        }
    }
}

/// A filename may contain newlines or Unicode direction controls. Render one
/// quoted logical path with visible escapes, without changing execution bytes.
enum InstallerPathDisplay {
    static func quoted(_ path: String) -> String {
        var rendered = "\""
        for scalar in path.unicodeScalars {
            switch scalar.value {
            case 0x22: rendered += "\\\""
            case 0x5C: rendered += "\\\\"
            case 0x0A: rendered += "\\n"
            case 0x0D: rendered += "\\r"
            case 0x09: rendered += "\\t"
            default:
                let value = scalar.value
                if CharacterSet.controlCharacters.contains(scalar) || value == 0x061C || value == 0xFEFF
                    || (0x200B...0x200F).contains(value) || (0x2028...0x202E).contains(value)
                    || (0x2060...0x206F).contains(value) {
                    rendered += "\\u{\(String(value, radix: 16).uppercased())}"
                } else { rendered.unicodeScalars.append(scalar) }
            }
        }
        return rendered + "\""
    }
}
