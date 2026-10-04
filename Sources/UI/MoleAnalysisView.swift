import AppKit
import SwiftUI

struct MoleAnalysisView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    private var analysis: MoleAnalysisStore { workspace.moleAnalysis }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Analyze with Mole", systemImage: "internaldrive").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { analysis.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Run the verified official Mole V1.57.0 analyzer on one folder after reviewing the scope. Cleanup remains unavailable.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 18) {
                selection(title: "Installed analyzer", value: analysis.executable?.path, action: chooseAnalyzer)
                selection(title: "Folder to analyze", value: analysis.directory?.path, action: chooseDirectory)
            }
            Text("Choose analyze-go from Mole’s official release installation. Homebrew and custom-built analyzers are not supported by this version check. MoeKit does not install or update tools.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Official Mole V1.57.0 release", destination: URL(string: "https://github.com/tw93/Mole/releases/tag/V1.57.0")!)
                .font(.caption)
            HStack {
                if analysis.isBusy {
                    ProgressView().controlSize(.small)
                    Text(analysis.isCancelling ? "Stopping analysis…" : (analysis.isPreparing ? "Verifying analyzer…" : "Analyzing selected folder…"))
                    Spacer()
                    Button("Cancel") { analysis.cancel() }.disabled(analysis.isCancelling)
                } else {
                    Button("Review analysis…") { analysis.prepare() }.disabled(!analysis.canPrepare)
                    Spacer()
                }
            }
            if let error = analysis.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            if let plan = analysis.plan { confirmation(plan) }
            if let result = analysis.result { resultView(result) }
            InstallerTrashView()
            if analysis.result == nil && analysis.plan == nil {
                ContentUnavailableView("No live analysis result", systemImage: "chart.bar.doc.horizontal", description:
                    Text("Selections do not start a process. Review the plan, then explicitly start analysis."))
            }
        }
        .padding(20)
        }
        .frame(minWidth: 720, minHeight: 560)
        .onDisappear { analysis.cancel() }
    }

    private func selection(title: LocalizedStringKey, value: String?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(value ?? String(localized: "Not selected")).font(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Button("Choose…", action: action).disabled(analysis.isBusy || analysis.isDemoEnabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirmation(_ plan: MoleAnalysisPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Text("Confirm folder analysis").font(.headline)
                Text(plan.directory.path).textSelection(.enabled)
                Text("Mole runs with your normal user permissions, without an OS sandbox. The reviewed analysis command does not delete or change selected-folder content; incidental metadata reads may extend beyond it.")
                Text("MoeKit will create a verified temporary analyzer copy and a fresh private cache/temp directory below the location shown here, then remove only that session after the process stops. Your existing Mole cache is not used.")
                Text(plan.privateSessionParent.path).font(.caption.monospaced()).textSelection(.enabled)
                Text("Analyzer limits: 120 seconds elapsed, 60 CPU seconds per process, 16 MB report and 64 KB diagnostics. Reports may be partial; sizes are not reclaimable space.")
                Text("\(plan.release.version) · \(plan.release.architecture) · SHA-256 \(plan.release.sha256)").font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("Cancel") { analysis.dismissPlan() }
                    Spacer()
                    Button("Start analysis") { analysis.confirm(planID: plan.id) }.buttonStyle(.borderedProminent)
                }
            }.padding(6)
        }
    }

    private func resultView(_ result: MoleAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(result.report.coverage.title, systemImage: result.report.coverage == .known ? "checkmark.circle" : "exclamationmark.triangle")
                Spacer()
                Text(result.finishedAt, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
            }
            Text("Live Mole result · filtered, non-atomic observation · sizes are not reclaimable space")
                .font(.caption).foregroundStyle(.secondary)
            Table(result.report.entries, selection: Binding<String?>(
                get: { workspace.installerTrash.selectedPath },
                set: { workspace.installerTrash.select(path: $0) }
            )) {
                TableColumn("Name") { entry in
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc").lineLimit(1)
                }
                TableColumn("Size") { entry in
                    if let bytes = entry.measuredBytes {
                        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                        Text(entry.coverage == .partial ? String(localized: "At least \(size)") : size).monospacedDigit()
                    } else { Text("Unknown").foregroundStyle(.secondary) }
                }.width(min: 100, ideal: 130)
                TableColumn("Read status") { entry in Text(entry.coverage.title).foregroundStyle(.secondary) }
            }.frame(minHeight: 200)
            Text("\(result.report.entries.count) entries · empty rows do not prove an empty disk").font(.caption).foregroundStyle(.secondary)
            Text("Only a directly listed .dmg in the current live Downloads analysis can be selected for independent native Trash review. Imported and Demo entries cannot be used.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseAnalyzer() {
        guard let ticket = analysis.selectionTicket() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the installed direct analyzer (analyze-go), not the mo shell wrapper.")
        if panel.runModal() == .OK, let url = panel.url { analysis.selectExecutable(url, ticket: ticket) }
    }
    private func chooseDirectory() {
        guard let ticket = analysis.selectionTicket() else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose one folder for a separately confirmed Mole analysis.")
        if panel.runModal() == .OK, let url = panel.url { analysis.selectDirectory(url, ticket: ticket) }
    }
}
