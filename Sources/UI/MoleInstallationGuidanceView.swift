import AppKit
import SwiftUI

/// Setup guidance never starts an installation. A supplied action opens the
/// reviewed terminal flow; the user still decides whether to submit its command.
@MainActor
struct MoleInstallationGuidanceView: View {
    let onRecheck: (() -> Void)?
    let isRecheckDisabled: Bool
    let isRechecking: Bool
    let installedSource: String?
    let upgradeTitle: String?
    let upgradeExplanation: String?
    let onUpgrade: (() -> Void)?
    let showsDownloadInstructions: Bool
    @State private var copiedCommand: String?
    @State private var showsCommand: Bool
    @State private var showsDetails: Bool

    init(onRecheck: (() -> Void)? = nil,
         isRecheckDisabled: Bool = false,
         isRechecking: Bool = false,
         showsCommand: Bool = false,
         showsDetails: Bool = false,
         installedSource: String? = nil,
         upgradeTitle: String? = nil,
         upgradeExplanation: String? = nil,
         showsDownloadInstructions: Bool = false,
         onUpgrade: (() -> Void)? = nil) {
        self.onRecheck = onRecheck
        self.isRecheckDisabled = isRecheckDisabled
        self.isRechecking = isRechecking
        self.installedSource = installedSource
        self.upgradeTitle = upgradeTitle
        self.upgradeExplanation = upgradeExplanation
        self.onUpgrade = onUpgrade
        self.showsDownloadInstructions = showsDownloadInstructions
        _showsCommand = State(initialValue: showsCommand)
        _showsDetails = State(initialValue: showsDetails)
    }

    private var release: MoleAnalyzerRelease { .native }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(m(installedSource == nil ? "Set up Mole" : "Use your installed Mole"))
                .font(.headline)
            Text(m("MoeKit reuses a verified installed analyzer. Keep the same installation source when upgrading."))
                .font(.callout).foregroundStyle(.secondary)
            if let installedSource {
                LabeledContent(m("Installation source"), value: installedSource)
                    .font(.callout)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(m("Recommended version"))
                Text(verbatim: MoleAnalyzerRelease.latestTestedVersion).fontWeight(.medium)
                Spacer(minLength: 12)
                Link(m("Official release notes"), destination: release.releaseURL)
            }.font(.callout)

            if let upgradeExplanation {
                Text(upgradeExplanation).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onUpgrade, let upgradeTitle {
                Button(upgradeTitle, action: onUpgrade)
                    .buttonStyle(.borderedProminent)
                    .disabled(isRecheckDisabled)
                    .accessibilityIdentifier("mole.setup.upgrade")
                Text(m("Opens a controlled terminal with the command ready to review. Only pressing Return there runs it."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if onRecheck == nil {
                Text(m("Open Mole → Space → Analyze with Mole… to check your version and see the next step."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            if showsDownloadInstructions {
                missingInstallationSteps
            }

            if let onRecheck {
                HStack(alignment: .center, spacing: 12) {
                    Button(m(isRechecking ? "Checking installation…" : "Recheck"), action: onRecheck)
                        .disabled(isRecheckDisabled)
                        .accessibilityIdentifier("mole.setup.installation.recheck")
                    Text(m("After installation or an upgrade, recheck before choosing a folder."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            DisclosureGroup(m("Installation details"), isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Link(m("Official Mole installation instructions"),
                         destination: URL(string: "https://github.com/tw93/Mole#quick-start")!)
                    Text(m("A newer version is not automatically downgraded. Verified source and tested compatibility are separate checks."))
                    Text(m("MoeKit checks the analyzer again before each run. Analysis still needs your separate folder confirmation."))
                    Text(m("If macOS blocks a file, review its warning first. Do not change download routes to bypass it."))
                }.font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }.font(.callout)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var missingInstallationSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m("No existing analyzer found"))
                .font(.callout.weight(.semibold))
            Text(m("Already installed somewhere else? Choose that analyzer in Advanced details. Otherwise, download the recommended official analyzer below."))
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup(m("Review download command"), isExpanded: $showsCommand) {
                ToolDownloadCommandView(command: release.manualDownloadCommand).padding(.top, 6)
            }
            Button(m(copiedCommand == release.manualDownloadCommand ? "Copied" : "Copy download command")) {
                let command = release.manualDownloadCommand
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(command, forType: .string) { copiedCommand = command }
            }.accessibilityIdentifier("mole.setup.copy-command")
            Text(m("Press ⌘ Space, open Terminal, then paste with ⌘V. Review the command and press Return to download."))
            Text(m("This downloads and checks one official analyzer in a new folder in your home directory. It does not run Mole, replace an installation or ask for an administrator password."))
            Text(m("Wait for “Mole analyzer ready”, then choose Recheck. If an error appears, stop and read it."))
            Text(InstallerPathDisplay.quoted("~/" + release.installationDirectoryName + "/analyze-go"))
                .font(.caption.monospaced()).textSelection(.enabled)
        }.font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func m(_ key: String) -> String { MoleSetupText.localized(key) }
}

enum MoleSetupText {
    static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), table: "MoleSetup")
    }
}
