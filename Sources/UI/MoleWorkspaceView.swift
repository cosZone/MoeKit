import SwiftUI

struct MoleWorkspaceView: View {
    @Environment(WorkspaceStore.self) private var store
    var body: some View {
        if store.selectedCapability == .space {
            MoleSpaceView()
        } else {
            VStack(spacing: 0) {
                HStack {
                    Label(store.selectedCapability.title, systemImage: store.selectedCapability.systemImage).fontWeight(.medium)
                    Spacer()
                    Text("Adapter not connected").foregroundStyle(.secondary)
                }.padding(.horizontal, 16).frame(height: 36)
                Divider()
                ContentUnavailableView {
                    Label(store.selectedCapability.title, systemImage: store.selectedCapability.systemImage)
                } description: {
                    Text(store.selectedCapability.readiness.explanation ?? String(localized: "This capability is not connected yet."))
                } actions: {
                    Button("Run", systemImage: "play") {}.disabled(true)
                }
                StatusBar(leading: String(localized: "No process has been started"), trailing: "Mole")
            }
        }
    }
}

private struct SpaceRow: Identifiable {
    let id: String
    let name: String
    let path: String
    let bytes: Int64?
    let coverage: MoleScanCoverage
    let isDirectory: Bool
    let lastAccess: Date?
    var sortBytes: Int64 { bytes ?? -1 }
    var sizeLabel: String {
        guard let bytes else { return String(localized: "Unknown") }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return coverage == .partial ? String(localized: "At least \(formatted)") : formatted
    }
}

private struct MoleSpaceView: View {
    @Environment(WorkspaceStore.self) private var store
    @State private var selection: SpaceRow.ID?
    @State private var sortOrder = [KeyPathComparator(\SpaceRow.sortBytes, order: .reverse)]
    @State private var showTreemap = false

    private var rows: [SpaceRow] {
        let source: [SpaceRow]
        if store.isDemoEnabled {
            let names = ["MoeKit", "node_modules", ".build", ".git", "motion-playground", "prompt-lab", "image-toolbox", "video-utils", "playground", "docs-site", "website-v2", "tiny-api", "swift-notes", "Other folders", "legacy-data", "client-archive"]
            let sizes: [Double?] = [46.2, 27.8, 12.6, 5.1, 24.5, 18.1, 13.7, 11.4, 9.6, 6.2, 4.5, 3.2, 2.1, 2.5, nil, nil]
            source = zip(names, sizes).map { name, value in
                let path = "/Users/demo/Code/\(name)"
                return SpaceRow(id: path, name: name, path: path, bytes: value.map { Int64($0 * 1_000_000_000) },
                                coverage: value == nil ? .unavailable : .known, isDirectory: true, lastAccess: nil)
            }
        } else {
            source = store.importedReport?.entries.map { entry in
                SpaceRow(id: entry.id, name: entry.name, path: entry.path, bytes: entry.measuredBytes,
                         coverage: entry.coverage, isDirectory: entry.isDirectory, lastAccess: entry.lastAccess)
            } ?? []
        }
        let filtered = source.filter { store.toolSearch.isEmpty || $0.name.localizedStandardContains(store.toolSearch) || $0.path.localizedStandardContains(store.toolSearch) }
            .sorted(using: sortOrder)
        // Keep unknown sizes visible rather than burying them below measured rows.
        return filtered.filter { $0.bytes == nil } + filtered.filter { $0.bytes != nil }
    }
    private var selectedRow: SpaceRow? { rows.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Space", systemImage: "internaldrive").fontWeight(.medium)
                Spacer()
                if store.isImporting { ProgressView().controlSize(.mini) }
                Text(store.isDemoEnabled ? "Example sizes" : "Imported report · upstream-reported sizes")
                    .foregroundStyle(.secondary)
            }.padding(.horizontal, 16).frame(height: 38)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(store.isDemoEnabled ? "/Users/demo/Code" : (store.importedReport?.path ?? String(localized: "No report imported")))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Picker("View", selection: $showTreemap) {
                    Text("List").tag(false)
                    Text("Treemap").tag(true)
                }.pickerStyle(.segmented).frame(width: 170)
                    .disabled(!canShowTreemap)
                    .help("Treemap requires complete, non-overlapping directory totals")
            }.padding(.horizontal, 16).frame(height: 36)
            Divider()
            if let report = store.importedReport, !store.isDemoEnabled {
                HStack {
                    Label(report.coverage.title, systemImage: report.coverage == .known ? "info.circle" : "exclamationmark.triangle")
                    Spacer()
                    if report.overview { Text("Overview locations may overlap") }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 28)
                Divider()
            }
            if showTreemap && canShowTreemap {
                SpaceTreemapView(rows: rows, selection: $selection)
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { row in
                        Label(row.name, systemImage: row.isDirectory ? "folder" : "doc")
                            .lineLimit(1).frame(minHeight: 23)
                    }.width(min: 200, ideal: 340, max: 550)
                    TableColumn("Size", value: \.sortBytes) { row in
                        Text(row.sizeLabel).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundStyle(row.bytes == nil ? Color.secondary : Color.primary)
                    }.width(min: 100, ideal: 140, max: 180)
                    TableColumn("Read status") { row in
                        Label(row.coverage.title, systemImage: row.coverage == .unavailable ? "exclamationmark.triangle" : "info.circle")
                            .font(.system(size: 12)).foregroundStyle(row.coverage == .unavailable ? Color.orange : Color.secondary).lineLimit(1)
                    }.width(min: 140, ideal: 190, max: 260)
                    TableColumn("Last access (reported)") { row in
                        if let date = row.lastAccess { Text(date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary) }
                        else { Text("—").foregroundStyle(.tertiary) }
                    }.width(min: 130, ideal: 150, max: 200)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .overlay {
                    if rows.isEmpty {
                        ContentUnavailableView {
                            Label(store.importedReport == nil ? "Explore a Mole space report" : "No matching entries", systemImage: "internaldrive")
                        } description: {
                            Text(store.importedReport == nil ? "Import an existing analyze --json report. CLI scanning will be connected in a later milestone." : "Try a different search. Empty results do not prove an empty disk.")
                        } actions: {
                            if store.importedReport == nil {
                                Button("Import report…") { store.chooseMoleReport() }.disabled(store.isDemoEnabled || store.isImporting)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedRow?.name ?? String(localized: "Select an entry")).fontWeight(.semibold)
                    Text(selectedRow?.path ?? String(localized: "Report data is not a cleanup plan"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(selectedRow?.sizeLabel ?? "").font(.caption).foregroundStyle(.secondary)
                Button("Add to review", systemImage: "checklist") {}.disabled(true)
                    .help("Selected-path mutation is not implemented. No cleanup command will be run.")
            }.padding(.horizontal, 16).frame(height: 64).background(MoeStyle.secondarySurface)
            StatusBar(leading: String(localized: "\(rows.count) entries · unknown sizes are not zero"),
                      trailing: store.isDemoEnabled ? String(localized: "Example data") : String(localized: "Report receipt time is not measurement time"))
        }
        .onChange(of: canShowTreemap) { if !canShowTreemap { showTreemap = false } }
        .onChange(of: store.isDemoEnabled) { selection = nil; showTreemap = false }
        .onChange(of: store.importedAt) { selection = nil; showTreemap = false }
    }
    private var canShowTreemap: Bool {
        // Demo data contains nested example locations; it is deliberately not summed.
        !store.isDemoEnabled && store.importedReport?.canShowAdditivePercentages == true && !rows.isEmpty
    }
}

/// A single-level, deterministic slice-and-dice treemap, drawn with native views.
/// It only visualizes an already validated directory report; it never scans.
private struct SpaceTreemapView: View {
    let rows: [SpaceRow]
    @Binding var selection: SpaceRow.ID?
    var body: some View {
        GeometryReader { geometry in
            let weighted = rows.filter { ($0.bytes ?? 0) > 0 }
            let total = weighted.reduce(0.0) { $0 + Double($1.bytes ?? 0) }
            HStack(spacing: 2) {
                ForEach(Array(weighted.enumerated()), id: \.element.id) { index, row in
                    Button { selection = row.id } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.name).fontWeight(.medium).lineLimit(2)
                            Text(row.sizeLabel).font(.caption).lineLimit(1)
                            Spacer()
                        }
                        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background([MoeStyle.blue, MoeStyle.lavender, MoeStyle.pink][index % 3].opacity(0.5))
                        .overlay(Rectangle().stroke(selection == row.id ? Color.accentColor : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(0, (geometry.size.width - CGFloat(max(0, weighted.count - 1) * 2)) * CGFloat(Double(row.bytes ?? 0) / max(1, total))))
                    .clipped().help("\(row.path) · \(row.sizeLabel)")
                }
            }
        }.padding(16)
    }
}
