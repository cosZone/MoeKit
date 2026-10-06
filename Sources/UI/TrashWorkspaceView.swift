import AppKit
import SwiftUI

@MainActor
struct TrashWorkspaceView: View {
    @Environment(WorkspaceStore.self) private var workspace
    private let suppliedStore: TrashStore?
    private var store: TrashStore { suppliedStore ?? workspace.trash }
    @State private var search = ""
    @State private var sortBySize = false
    init(store: TrashStore? = nil) { suppliedStore = store }
    private var visibleItems: [TrashItem] {
        let filtered = store.items.filter { search.isEmpty || $0.url.lastPathComponent.localizedStandardContains(search) }
        return filtered.sorted {
            if sortBySize, $0.logicalBytes != $1.logicalBytes { return ($0.logicalBytes ?? -1) > ($1.logicalBytes ?? -1) }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Trash", systemImage: "trash").fontWeight(.medium)
                    .installerCaptureIdentity("trash.heading", text: String(localized: "Trash"))
                Spacer()
                Text("Your home Trash only").foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(height: 38)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    introduction
                    controls
                    if store.isBusy { operationProgress }
                    if let progress = store.scanProgress { DiskInventoryProgressView(progress: progress) }
                    if let error = store.errorMessage { warning(error) }
                    if let inspection = store.inspection { inventory(inspection) }
                    if let plan = store.plan { confirmation(plan) }
                    if let outcome = store.lastOutcome { outcomes(outcome) }
                    if let error = store.lastMutationError { warning(error).installerCaptureIdentity("trash.mutation.error", text: error) }
                    records
                }.padding(20)
            }
            StatusBar(leading: String(localized: "Permanent deletion cannot be undone"), trailing: "MoeKit · Native")
        }
        .onDisappear { store.cancel() }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose items to delete").font(.title2.weight(.semibold))
            Text("Scan your home Trash, then select items to review. Deletion is permanent. Clearing the scanned items also requires typing EMPTY.")
            DisclosureGroup("Scan details") {
                Text("External-volume Trash and other users’ Trash are not included. Original locations and deletion dates are unavailable; Last modified is the file’s modification date. Symbolic links are listed as links and never followed.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
            if store.isDemoEnabled {
                Label("Trash operations are unavailable in Demo. Actual results from this session remain visible.", systemImage: "lock").foregroundStyle(.secondary)
            }
        }
    }
    private var controls: some View {
        HStack {
            Button("Scan home Trash", systemImage: "arrow.clockwise") { store.inspect() }.disabled(!store.canInspect)
                .installerCaptureIdentity("trash.scan", text: String(localized: "Scan home Trash"))
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([TrashEnvironment.user.trash])
            }.disabled(store.isDemoEnabled || store.isBusy)
            Spacer()
        }
    }
    private var operationProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let progress = store.progress {
                    ProgressView(value: Double(progress.finished), total: Double(max(1, progress.total))).frame(width: 120)
                    Text("\(progress.finished) of \(progress.total) items processed").monospacedDigit()
                } else { ProgressView().controlSize(.small) }
                Text(store.isCancelling ? "Waiting for the actual Trash outcome…" : "Checking the Trash operation…")
                    .installerCaptureIdentity("trash.progress.state", text: store.isCancelling ? String(localized: "Waiting for the actual Trash outcome…") : String(localized: "Checking the Trash operation…"))
                Spacer()
                Button("Cancel") { store.cancel() }.disabled(store.isCancelling)
            }
            if let current = store.progress?.currentPath {
                Text(InstallerPathDisplay.quoted(current)).font(.caption.monospaced()).textSelection(.enabled)
            }
            Text("Cancellation stops before the next mutation when possible. Completed deletions cannot be undone. Remaining and uncertain data is retained; check the per-item results.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func inventory(_ inspection: TrashInspection) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                path("Trash location", inspection.rootURL, id: "trash.root")
                Text("Scanned at \(inspection.observedAt.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
                ForEach(inspection.issues, id: \.self) { warning($0) }
                if inspection.items.isEmpty && inspection.listingIsComplete {
                    Label("Your home Trash is empty", systemImage: "trash").font(.headline).padding(.vertical, 12)
                    Text("This scan does not include external volumes.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        TextField("Filter Trash names", text: $search).textFieldStyle(.roundedBorder)
                        Toggle("Largest first", isOn: $sortBySize).toggleStyle(.checkbox)
                    }
                    Table(visibleItems, selection: Binding(get: { store.selectedPaths }, set: { store.select(paths: $0) })) {
                        TableColumn("Item") { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(InstallerPathDisplay.quoted(item.url.lastPathComponent), systemImage: symbol(item))
                                if let blocker = item.blocker { Text(blocker).font(.caption).foregroundStyle(.orange) }
                            }
                        }.width(min: 220, ideal: 320)
                        TableColumn("Logical size") { item in
                            Text(item.displayedSize).monospacedDigit().help(item.sizeEstimate?.issues.joined(separator: "\n") ?? "")
                        }.width(min: 90, ideal: 105)
                        TableColumn("Last modified") { item in
                            if let date = item.modifiedAt { Text(date, format: .dateTime.year().month().day()).font(.caption) }
                            else { Text("Unavailable").foregroundStyle(.secondary) }
                        }.width(min: 100, ideal: 120)
                        TableColumn("Original location") { _ in Text("Unavailable").foregroundStyle(.secondary) }.width(min: 100, ideal: 120)
                    }.frame(minHeight: 180, idealHeight: 280, maxHeight: 380).disabled(store.isBusy || store.isDemoEnabled)
                    Text("\(store.selectedPaths.count) selected · \(inspection.items.count) scanned items").font(.caption).monospacedDigit()
                    HStack {
                        Button("Select eligible items") { store.select(paths: Set(store.items.filter(\.isEligible).map(\.id))) }
                            .disabled(!store.canInspect)
                        Button("Deselect all") { store.select(paths: []) }.disabled(!store.canInspect || store.selectedPaths.isEmpty)
                        Spacer()
                        Button("Review selected items…") { store.prepare(action: .selectedItems) }.disabled(!store.canPrepare)
                        Button("Review all scanned items…") { store.prepare(action: .clearSnapshot) }.disabled(!store.canClear)
                    }
                    if !inspection.canClearSnapshot {
                        Text("Clear scanned Trash is unavailable while any item is unreadable or unsupported. You can select the eligible items individually.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Readable sizes remain available for protected items. Partial sizes include only inspected file metadata; no link targets are followed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Filtering changes the visible rows only. Review always lists every selected item, including selected items hidden by the filter.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }
    private func confirmation(_ plan: TrashRemovalPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(plan.action == .clearSnapshot ? "Permanently delete all scanned items?" : "Permanently delete selected items?")
                    .font(.headline).installerCaptureIdentity("trash.review.heading", text: plan.action == .clearSnapshot ? String(localized: "Permanently delete all scanned items?") : String(localized: "Permanently delete selected items?"))
                Text("Only the items and contents listed below will be permanently deleted. Trash and MoeKit cannot restore them. New arrivals are not included.")
                    .foregroundStyle(.red).installerCaptureIdentity("trash.review.effects", text: String(localized: "Only the items and contents listed below will be permanently deleted. Trash and MoeKit cannot restore them. New arrivals are not included."))
                Text("\(plan.items.count) Trash items · \(size(plan.logicalBytes)) logical size").monospacedDigit()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(plan.items) { item in
                            path("Exact Trash item", item.url)
                            if let manifest = item.manifest {
                                ForEach(manifest.entries, id: \.relativePath) { entry in
                                    let url = entry.relativePath.isEmpty ? item.url : item.url.appendingPathComponent(entry.relativePath)
                                    Label(InstallerPathDisplay.quoted(url.path), systemImage: entry.kind == .directory ? "folder" : (entry.kind == .symbolicLink ? "link" : "doc"))
                                        .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }.frame(minHeight: 100, maxHeight: 280).background(MoeStyle.secondarySurface)
                Text("Close apps and workloads using these items first. Identity checks do not prove global non-use. Hard links, open files, clones and APFS snapshots may reduce or delay physical space reclaimed.")
                    .font(.caption).foregroundStyle(.secondary)
                path("Private operation records and retained data", plan.recoveryURL, id: "trash.review.records")
                Text("Confirmation creates private records containing the reviewed paths. If interrupted, remaining or changed data stays in that operation folder for manual inspection. No automatic retry, restore, or record cleanup occurs.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("I have stopped apps and workloads using these Trash items", isOn: Binding(
                    get: { store.workloadsStopped }, set: { store.attestWorkloadsStopped($0, planID: plan.id) }))
                    .installerCaptureIdentity("trash.review.workloads", text: String(localized: "I have stopped apps and workloads using these Trash items"))
                Toggle("I understand every listed item will be permanently deleted and cannot be restored", isOn: Binding(
                    get: { store.irreversibleAccepted }, set: { store.attestIrreversible($0, planID: plan.id) }))
                    .installerCaptureIdentity("trash.review.irreversible", text: String(localized: "I understand every listed item will be permanently deleted and cannot be restored"))
                if plan.action == .clearSnapshot {
                    HStack {
                        Text("Type EMPTY to confirm this complete snapshot")
                        TextField("EMPTY", text: Binding(get: { store.typedConfirmation }, set: { store.typeConfirmation($0, planID: plan.id) }))
                            .textFieldStyle(.roundedBorder).frame(width: 130)
                            .accessibilityIdentifier("trash.review.typed-confirmation")
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Confirmation expires at \(plan.expiresAt.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Cancel plan") { store.cancel() }.installerCaptureIdentity("trash.review.cancel", text: String(localized: "Cancel plan"))
                            Spacer()
                            Button("Permanently delete", role: .destructive) { store.confirm(planID: plan.id) }
                                .disabled(!store.canConfirm(planID: plan.id))
                                .installerCaptureIdentity("trash.review.confirm", text: String(localized: "Permanently delete"))
                        }
                    }
                }
            }.padding(6)
        }
    }
    private func outcomes(_ outcome: TrashOutcome) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Deletion results").font(.headline)
                    .installerCaptureIdentity("trash.outcome.heading", text: String(localized: "Deletion results"))
                if store.isDemoEnabled { Text("Actual operations from this session, not example data").font(.caption) }
                ForEach(outcome.items) { item in
                    path("Reviewed Trash path", item.originalURL)
                    Label(item.message, systemImage: item.status == .deleted ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(item.status == .deleted ? Color.primary : Color.orange).textSelection(.enabled)
                    if let operation = item.operationURL { showOperation(operation) }
                    Divider()
                }
                Text("Scan again for the current contents. Later arrivals and unattempted items were not included in the completed deletion.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
    private var records: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Previous operations").font(.headline)
                    Spacer()
                    Button("Load records") { store.readRecords() }.disabled(!store.canReadRecords)
                }
                Text("The latest 128 operation records are shown. Older records remain in the private records folder.").font(.caption).foregroundStyle(.secondary)
                Text("Read-only history of this Trash adapter. An interrupted operation may retain a payload and individual delete-entry slots. Inspect all contents manually; these records do not authorize another deletion.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.hasReadRecords && store.recoveryItems.isEmpty { Text("No previous operations").foregroundStyle(.secondary) }
                ForEach(store.recoveryItems) { item in
                    if let record = item.record {
                        Label(record.state == .deleted ? "Recorded deletion completed" : "Operation requires manual inspection", systemImage: record.state == .deleted ? "checkmark.circle" : "exclamationmark.triangle")
                        path("Reviewed Trash path", record.originalURL)
                        Text(record.recordedAt, format: .dateTime).font(.caption)
                    } else { warning(item.issue ?? String(localized: "Operation requires manual inspection")) }
                    showOperation(item.operationURL)
                    Divider()
                }
            }.padding(6)
        }
    }
    private func showOperation(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            path("Operation folder", url)
            Button("Reveal operation folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
    private func symbol(_ item: TrashItem) -> String {
        switch item.manifest?.entries.first?.kind {
        case .directory: "folder"
        case .symbolicLink: "link"
        case .file: "doc"
        case nil: "exclamationmark.triangle"
        }
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func path(_ title: LocalizedStringKey, _ url: URL, id: String = "") -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(InstallerPathDisplay.quoted(url.path)).font(.callout.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).installerCaptureIdentity(id, text: InstallerPathDisplay.quoted(url.path))
        }
    }
    private func warning(_ value: String) -> some View {
        Label(value, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
    }
}
