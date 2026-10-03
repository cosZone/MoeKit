import SwiftUI

/// An explicit, read-only snapshot. Entering this workspace never starts a scan.
struct ProcessWorkspaceView: View {
    @Environment(WorkspaceStore.self) private var store

    private var inventory: ProcessInventoryStore { store.processes }
    private var selectedRecord: ProcessInventoryRecord? {
        guard inventory.selection.count == 1 else { return nil }
        return inventory.rows.first { inventory.selection.contains($0.id) }
    }

    var body: some View {
        @Bindable var inventory = inventory
        Group {
            if store.isDemoEnabled {
                ContentUnavailableView {
                    Label("Processes & Ports", systemImage: "terminal")
                } description: {
                    Text("Process scanning is unavailable in Demo. Exit Demo to explicitly scan your current user’s processes.")
                }
            } else {
                VStack(spacing: 0) {
                    snapshotHeader
                    Divider()
                    if let error = inventory.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                        Divider()
                    }
                    VSplitView {
                        processTable
                            .frame(minHeight: 180)
                        selectionDetails
                            .frame(minHeight: 170, idealHeight: 230, maxHeight: 380)
                    }
                    StatusBar(
                        leading: String(localized: "\(inventory.rows.count) processes · \(inventory.selection.count) selected"),
                        trailing: String(localized: "Read-only · no process signals are sent")
                    )
                }
            }
        }
        .sheet(item: Binding(
            get: { store.isDemoEnabled ? nil : inventory.plan },
            set: { inventory.plan = $0 }
        )) { plan in
            ProcessStopPlanView(plan: plan)
        }
        .onChange(of: inventory.rows.map(\.id)) { _, visibleIDs in
            inventory.selection.formIntersection(Set(visibleIDs))
        }
    }

    private var snapshotHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Processes & Ports", systemImage: "terminal").fontWeight(.medium)
                if inventory.isScanning {
                    ProgressView().controlSize(.mini)
                    Text("Scanning…").foregroundStyle(.secondary)
                }
                Spacer()
                if let snapshot = inventory.snapshot {
                    Text("Current UID: \(Int(snapshot.currentUID))").foregroundStyle(.secondary)
                    Label(snapshot.isPartial ? "Partial snapshot" : "Snapshot", systemImage: snapshot.isPartial ? "exclamationmark.triangle" : "clock")
                        .foregroundStyle(snapshot.isPartial ? Color.orange : Color.secondary)
                    Text(snapshot.capturedAt, format: .dateTime.year().month().day().hour().minute().second())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not scanned").foregroundStyle(.secondary)
                }
            }
            if let projectID = inventory.projectFilterID {
                HStack(spacing: 8) {
                    Label(inventory.projects.first { $0.id == projectID }?.name ?? String(localized: "Selected project"), systemImage: "folder")
                    Text("Inferred from working directory").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show all processes") { inventory.projectFilterID = nil }
                        .buttonStyle(.borderless)
                }
            }
            Text("Current user only. TCP listening ports and project associations reflect this snapshot; unknown readings are not empty results.")
                .font(.caption).foregroundStyle(.secondary)
            if let snapshot = inventory.snapshot, !snapshot.issues.isEmpty {
                DisclosureGroup("Scan diagnostics") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(snapshot.issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.textSelection(.enabled)
                    }.frame(maxHeight: 90)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var processTable: some View {
        @Bindable var inventory = inventory
        return Table(inventory.rows, selection: $inventory.selection) {
            TableColumn("Name") { record in
                Label(record.name.isEmpty ? ProcessPresentation.unknown : record.name, systemImage: "terminal")
                    .lineLimit(1).frame(minHeight: 23)
                    .help(record.name)
            }.width(min: 130, ideal: 190, max: 340)
            TableColumn("PID") { record in
                Text(String(record.identity.pid)).monospacedDigit()
            }.width(min: 55, ideal: 65, max: 85)
            TableColumn("Listening ports") { record in
                Text(ProcessPresentation.portSummary(record.listeningPorts))
                    .foregroundStyle(.secondary).lineLimit(1)
                    .help(ProcessPresentation.portDetails(record.listeningPorts))
            }.width(min: 110, ideal: 140, max: 220)
            TableColumn("Project") { record in
                let association = inventory.association(for: record)
                Text(association.projectName ?? association.title)
                    .foregroundStyle(.secondary).lineLimit(1)
                    .help(association.evidence)
            }.width(min: 125, ideal: 180, max: 300)
            TableColumn("Protection") { record in
                let reasons = inventory.protectionReasons(for: record)
                Label(reasons.isEmpty ? "No flagged risks" : "Protected", systemImage: reasons.isEmpty ? "info.circle" : "shield.lefthalf.filled")
                    .foregroundStyle(reasons.isEmpty ? Color.secondary : Color.orange)
                    .lineLimit(1).help(reasons.joined(separator: "\n"))
            }.width(min: 120, ideal: 145, max: 200)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if inventory.rows.isEmpty {
                ContentUnavailableView {
                    Label(inventory.snapshot == nil ? "Inspect running processes" : "No matching processes", systemImage: "terminal")
                } description: {
                    Text(inventory.snapshot == nil
                         ? "Start a bounded, read-only scan when you’re ready. Nothing is scanned automatically."
                         : "Try another search or project filter. A partial snapshot may omit unreadable processes.")
                }
            }
        }
    }

    private var selectionDetails: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Process details").fontWeight(.semibold)
                Spacer()
                Button("Review stop plan", systemImage: "checklist") {
                    guard !store.isDemoEnabled else { return }
                    inventory.reviewSelection()
                }
                    .disabled(store.isDemoEnabled || inventory.isScanning || inventory.selection.isEmpty)
                    .help("Inspect exact targets and risks. Stopping processes is unavailable.")
            }.padding(.horizontal, 16).frame(height: 38).background(MoeStyle.secondarySurface)
            if let record = selectedRecord {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ProcessRecordDetails(record: record)
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                            ProcessDetailRow(title: "Project", value: inventory.association(for: record).projectName ?? ProcessPresentation.unknown)
                            ProcessDetailRow(title: "Project association", value: inventory.association(for: record).title)
                            ProcessDetailRow(title: "Association evidence", value: inventory.association(for: record).evidence)
                            ProcessDetailRow(title: "Protection", value: protectionText(for: record))
                        }
                        if !record.metadataIssues.isEmpty {
                            Text("Unavailable metadata").fontWeight(.medium)
                            ForEach(Array(record.metadataIssues.enumerated()), id: \.offset) { _, issue in
                                Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                            }
                        }
                    }.font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(inventory.selection.isEmpty ? "Select a process" : "Multiple processes selected").fontWeight(.medium)
                    Text(inventory.selection.isEmpty
                         ? "Select a row to inspect identity, listening ports, project evidence, and protection reasons."
                         : "Review the plan to inspect every selected identity and its risks. No stop action is available.")
                        .foregroundStyle(.secondary)
                }.font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            }
        }
    }

    private func protectionText(for record: ProcessInventoryRecord) -> String {
        let reasons = inventory.protectionReasons(for: record)
        return reasons.isEmpty ? String(localized: "No flagged risks. This is not a safety guarantee.") : reasons.joined(separator: "\n")
    }
}

private struct ProcessRecordDetails: View {
    let record: ProcessInventoryRecord

    private var identity: ProcessIdentity { record.identity }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            ProcessDetailRow(title: "Name", value: record.name.isEmpty ? ProcessPresentation.unknown : record.name)
            ProcessDetailRow(title: "PID", value: String(identity.pid))
            ProcessDetailRow(title: "Started", value: identity.startedAt?.formatted(date: .abbreviated, time: .complete) ?? ProcessPresentation.unknown)
            ProcessDetailRow(title: "Start identity (s / µs)", value: ProcessPresentation.startIdentity(identity))
            ProcessDetailRow(title: "UID", value: identity.uid.map { String($0) } ?? ProcessPresentation.unknown)
            ProcessDetailRow(title: "Executable path", value: identity.executablePath ?? ProcessPresentation.unknown)
            ProcessDetailRow(title: "Parent PID", value: record.parentPID.map { String($0) } ?? ProcessPresentation.unknown)
            ProcessDetailRow(title: "Process group", value: record.processGroupID.map { String($0) } ?? ProcessPresentation.unknown)
            ProcessDetailRow(title: "Working directory", value: record.workingDirectory ?? ProcessPresentation.unknown)
            ProcessDetailRow(title: "Listening ports", value: ProcessPresentation.portDetails(record.listeningPorts))
        }
    }
}

private struct ProcessDetailRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ProcessStopPlanView: View {
    @Environment(\.dismiss) private var dismiss
    let plan: StopPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Label("Review stop plan", systemImage: "checklist").font(.title2).fontWeight(.semibold)
                Text("Inspection only. Process stopping, graceful termination, and force termination are unavailable. No signals will be sent.")
                    .foregroundStyle(.secondary)
                LabeledContent("Snapshot", value: plan.snapshotDate.formatted(date: .abbreviated, time: .complete))
                    .font(.caption)
                LabeledContent("Snapshot ID", value: plan.snapshotID.uuidString).font(.caption).textSelection(.enabled)
                Text("\(plan.targets.count) exact targets").font(.caption).fontWeight(.medium)
            }.padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !plan.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Plan warnings").fontWeight(.semibold)
                            ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                            }
                        }.foregroundStyle(.orange)
                    }
                    ForEach(plan.targets) { target in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                ProcessRecordDetails(record: target.record)
                                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                                    ProcessDetailRow(title: "Project", value: target.association.projectName ?? ProcessPresentation.unknown)
                                    ProcessDetailRow(title: "Project association", value: target.association.title)
                                    ProcessDetailRow(title: "Association evidence", value: target.association.evidence)
                                }
                                if target.risks.isEmpty {
                                    Text("No flagged risks. This is not a safety guarantee.").foregroundStyle(.secondary)
                                } else {
                                    ForEach(Array(target.risks.enumerated()), id: \.offset) { _, risk in
                                        Label(risk, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                    }
                                }
                            }.font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Label("Execution unavailable", systemImage: "lock").foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
        }.frame(minWidth: 620, idealWidth: 700, minHeight: 480, idealHeight: 620)
    }
}

private enum ProcessPresentation {
    static var unknown: String { String(localized: "Unknown") }

    static func portSummary(_ ports: [ListeningPort]?) -> String {
        guard let ports else { return unknown }
        guard !ports.isEmpty else { return String(localized: "None observed") }
        return Set(ports.map { "\($0.transport) \($0.port)" }).sorted().joined(separator: ", ")
    }

    static func portDetails(_ ports: [ListeningPort]?) -> String {
        guard let ports else { return unknown }
        guard !ports.isEmpty else { return String(localized: "None observed") }
        return ports.map { "\($0.transport) \($0.address) · \($0.port)" }.joined(separator: "\n")
    }

    static func startIdentity(_ identity: ProcessIdentity) -> String {
        guard let seconds = identity.startSeconds, let microseconds = identity.startMicroseconds else { return unknown }
        return "\(seconds) / \(microseconds)"
    }
}
