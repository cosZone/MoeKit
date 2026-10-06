import AppKit
import SwiftUI

@MainActor
struct MoleAnalysisView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var showsAdvanced: Bool
    @State private var showsInstallation: Bool
    @State private var showsInstallerActions = false
    private var analysis: MoleAnalysisStore { workspace.moleAnalysis }

    init(showsAdvanced: Bool = false, showsInstallation: Bool = false) {
        _showsAdvanced = State(initialValue: showsAdvanced)
        _showsInstallation = State(initialValue: showsInstallation)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Analyze with Mole", systemImage: "internaldrive").font(.title2.weight(.semibold))
                Spacer()
                Button("Close") { analysis.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(m("Find what is taking up space in a folder."))
                        .foregroundStyle(.secondary)
                    installationStatus
                    if analysis.isBusy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(activityTitle)
                            Spacer()
                            Button("Cancel") { analysis.cancel() }.disabled(analysis.isCancelling)
                        }
                    }
                    if !analysis.isDemoEnabled {
                        DisclosureGroup(m("Set up Mole"), isExpanded: $showsInstallation) {
                            MoleInstallationGuidanceView(
                                onRecheck: { analysis.discoverInstalledAnalyzer() },
                                isRecheckDisabled: analysis.isBusy,
                                isRechecking: analysis.isDiscovering
                            ).padding(.top, 10)
                        }
                    }
                    folderSelection
                    if let error = analysis.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let plan = analysis.plan { confirmation(plan) }
                    if let result = analysis.result { resultView(result) }
                    advancedOptions
                    DisclosureGroup(m("Downloaded installers and recovery"), isExpanded: $showsInstallerActions) {
                        InstallerTrashView().padding(.top, 8)
                    }
                }.padding(20)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .task {
            revealNextSetupStep()
            analysis.discoverIfNeeded()
        }
        .onChange(of: analysis.installation?.inspectedAt) { _, date in
            guard date != nil else { return }
            revealNextSetupStep()
        }
        .onChange(of: workspace.installerTrash.selectedPath) { _, path in
            if path != nil { showsInstallerActions = true }
        }
        .onDisappear { analysis.cancel() }
    }

    private func revealNextSetupStep() {
        guard let installation = analysis.installation else { return }
        switch installation.state {
        case .missing, .incompatible: showsInstallation = true
        case .unverified:
            // Show the reason first, especially when macOS has blocked a file.
            // A second download must not be presented as a security bypass.
            showsInstallation = false
            showsAdvanced = true
        case .usable: showsInstallation = false
        }
    }

    private var installationStatus: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: statusSymbol).font(.title2).foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m("1. Check Mole")).font(.caption).foregroundStyle(.secondary)
                        Text(statusTitle).font(.headline)
                            .accessibilityIdentifier("mole.setup.status")
                        Text(statusExplanation).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(m("Recheck")) { analysis.discoverInstalledAnalyzer() }
                        .disabled(analysis.isBusy || analysis.isDemoEnabled)
                        .accessibilityIdentifier("mole.setup.recheck")
                }
                if let report = analysis.installation, !analysis.isDiscovering {
                    HStack(spacing: 4) {
                        Text(m("Last checked"))
                        Text(report.inspectedAt, format: .dateTime.month().day().hour().minute())
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var folderSelection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(m("2. Choose a folder")).font(.headline)
                Text(m("Choose a folder. Analysis starts only after your confirmation."))
                    .font(.callout).foregroundStyle(.secondary)
                if let directory = analysis.directory {
                    Label(InstallerPathDisplay.quoted(directory.path), systemImage: "folder")
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mole.setup.folder")
                }
                HStack {
                    Button(m(analysis.directory == nil ? "Choose folder…" : "Change folder…")) { chooseDirectory() }
                        .disabled(analysis.isBusy || analysis.isDemoEnabled)
                        .accessibilityIdentifier("mole.setup.choose-folder")
                    Spacer()
                    Button("Review analysis…") { analysis.prepare() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!analysis.canPrepare)
                        .accessibilityIdentifier("mole.setup.review")
                }
                if analysis.executable == nil && !analysis.isDemoEnabled {
                    Text(m("Finish Mole setup first."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if analysis.directory == nil && !analysis.isDemoEnabled {
                    Text(m("Choose a folder to continue."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var advancedOptions: some View {
        DisclosureGroup(m("Advanced details"), isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                Text(m("Use this if you installed the official analyzer somewhere else. Choosing a file does not verify it; Review analysis checks it before offering a confirmation."))
                    .font(.callout).foregroundStyle(.secondary)
                if let executable = analysis.executable {
                    Text(InstallerPathDisplay.quoted(executable.path)).font(.caption.monospaced())
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Button(m("Choose analyzer file…")) { chooseAnalyzer() }
                    .disabled(analysis.isBusy || analysis.isDemoEnabled)
                    .accessibilityIdentifier("mole.setup.choose-analyzer")
                if let report = analysis.installation {
                    Divider()
                    Text(m("Checked locations")).font(.headline)
                    Text(m("Only fixed installation locations are checked. No folder scan, shell, version command or analyzer process is started."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(report.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top) {
                                Text(candidate.source).fontWeight(.medium)
                                Spacer()
                                Text(stateTitle(candidate.state)).foregroundStyle(.secondary)
                            }.font(.caption)
                            Text(InstallerPathDisplay.quoted(candidate.path)).font(.caption.monospaced())
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text(candidate.explanation).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if candidate.id != report.candidates.last?.id { Divider() }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
        }
    }

    private var isManualSelection: Bool {
        analysis.executable != nil && analysis.executable != analysis.installation?.verifiedExecutable
    }

    private var statusTitle: String {
        if analysis.isDemoEnabled { return m("Setup is unavailable in Demo") }
        if analysis.isDiscovering { return m("Checking for Mole…") }
        if isManualSelection {
            return m(analysis.plan == nil ? "Selected manually · unverified" : "Analyzer verified for this review")
        }
        guard let state = analysis.installation?.state else { return m("Installation not checked") }
        return stateTitle(state)
    }

    private var statusExplanation: String {
        if analysis.isDemoEnabled { return m("Exit Demo to set up Mole and analyze your folders.") }
        if analysis.isDiscovering { return m("Checking known locations and verifying the analyzer. Mole is not running.") }
        if isManualSelection {
            return m(analysis.plan == nil
                ? "A file was selected manually. Choose a folder, then use Review analysis to verify that file."
                : "Read the confirmation below. The analyzer is checked again when you start the analysis.")
        }
        guard let state = analysis.installation?.state else {
            return m("Choose Recheck to look for a supported analyzer. This check does not run Mole or install anything.")
        }
        switch state {
        case .usable: return m("Mole V1.57.0 is verified. Choose a folder below.")
        case .missing: return m("Not found in the checked locations. Follow the setup guide, or choose your file in Advanced details.")
        case .incompatible: return m("This file is incompatible. Use the official V1.57.0 analyzer in the guide below.")
        case .unverified: return m("Verification failed. Read the reason in Advanced details before continuing.")
        }
    }

    private var statusSymbol: String {
        if analysis.isDemoEnabled { return "info.circle" }
        if analysis.isDiscovering { return "magnifyingglass" }
        if isManualSelection { return analysis.plan == nil ? "questionmark.circle" : "checkmark.shield" }
        switch analysis.installation?.state {
        case .some(.usable): return "checkmark.circle.fill"
        case .some(.missing): return "arrow.down.circle"
        case .some(.incompatible): return "exclamationmark.triangle"
        case .some(.unverified): return "questionmark.circle"
        case nil: return "magnifyingglass"
        }
    }

    private var statusColor: Color {
        if analysis.isDemoEnabled || analysis.isDiscovering { return .secondary }
        if isManualSelection { return analysis.plan == nil ? .orange : .green }
        switch analysis.installation?.state {
        case .some(.usable): return .green
        case .some(.incompatible), .some(.unverified): return .orange
        default: return .secondary
        }
    }

    private var activityTitle: String {
        if analysis.isCancelling { return m("Stopping the current operation…") }
        if analysis.isDiscovering { return m("Checking installation…") }
        return analysis.isPreparing ? String(localized: "Verifying analyzer…") : String(localized: "Analyzing selected folder…")
    }

    private func stateTitle(_ state: MoleInstallationState) -> String {
        switch state {
        case .usable: return m("Ready to analyze")
        case .missing: return m("Analyzer not found")
        case .incompatible: return m("Analyzer is incompatible")
        case .unverified: return m("Analyzer not verified")
        }
    }

    private func m(_ key: String) -> String { MoleSetupText.localized(key) }

    private func confirmation(_ plan: MoleAnalysisPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Text("Confirm folder analysis").font(.headline)
                Text(InstallerPathDisplay.quoted(plan.directory.path)).textSelection(.enabled)
                Text("Mole runs with your normal user permissions, without an OS sandbox. The reviewed analysis command does not delete or change selected-folder content; incidental metadata reads may extend beyond it.")
                Text("MoeKit will create a verified temporary analyzer copy and a fresh private cache/temp directory below the location shown here, then remove only that session after the process stops. Your existing Mole cache is not used.")
                Text(InstallerPathDisplay.quoted(plan.privateSessionParent.path)).font(.caption.monospaced()).textSelection(.enabled)
                Text("Reports may be incomplete. Reported sizes are not space you can necessarily free.")
                DisclosureGroup(m("Analyzer verification details")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(InstallerPathDisplay.quoted(plan.executable.path))
                        Text("\(plan.release.version) · \(plan.release.architecture) · SHA-256 \(plan.release.sha256)")
                        Text("Analyzer limits: 120 seconds elapsed, 60 CPU seconds per process, 16 MB report and 64 KB diagnostics. Reports may be partial; sizes are not reclaimable space.")
                    }.font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        panel.resolvesAliases = false
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
