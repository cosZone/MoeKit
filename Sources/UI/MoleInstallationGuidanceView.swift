import AppKit
import SwiftUI

/// Display and clipboard guidance only. No installation or shell action is wired
/// to this view; the same steps are used by analysis and tool preparation.
@MainActor
struct MoleInstallationGuidanceView: View {
    let onRecheck: (() -> Void)?
    let isRecheckDisabled: Bool
    let isRechecking: Bool
    @State private var copiedCommand: String?
    @State private var showsCommand: Bool
    @State private var showsDetails: Bool

    init(onRecheck: (() -> Void)? = nil,
         isRecheckDisabled: Bool = false,
         isRechecking: Bool = false,
         showsCommand: Bool = false,
         showsDetails: Bool = false) {
        self.onRecheck = onRecheck
        self.isRecheckDisabled = isRecheckDisabled
        self.isRechecking = isRechecking
        _showsCommand = State(initialValue: showsCommand)
        _showsDetails = State(initialValue: showsDetails)
    }

    private var release: MoleAnalyzerRelease { .native }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(m("Install the supported Mole analyzer")).font(.headline)
            Text(m("You only need the official V1.57.0 analyzer for this Mac. Homebrew and source-built versions do not match this app's compatibility check."))
                .font(.callout).foregroundStyle(.secondary)
            Text("A browser download may have a macOS quarantine marker. MoeKit refuses quarantined files; neither this command nor MoeKit removes that marker or bypasses Gatekeeper. Do not retry a blocked file through another download route to evade a security warning.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            step(1, m("Review the official download")) {
                Link("Official Mole V1.57.0 release", destination: release.releaseURL)
                Text(m("Read the release notes and review the command in step 3. The command downloads one official file, checks it, and makes it ready for MoeKit. It does not run Mole or ask for an administrator password."))
                    .foregroundStyle(.secondary)
            }
            step(2, m("Open Terminal")) {
                Text(m("Press ⌘ Space to open Spotlight, type Terminal, then press Return."))
                    .foregroundStyle(.secondary)
            }
            step(3, m("Copy, paste and run the command")) {
                DisclosureGroup("Review download command", isExpanded: $showsCommand) {
                    ToolDownloadCommandView(command: release.manualDownloadCommand).padding(.top, 6)
                }
                Button(copiedCommand == release.manualDownloadCommand
                       ? String(localized: "Copied") : String(localized: "Copy download command")) {
                    let command = release.manualDownloadCommand
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(command, forType: .string) { copiedCommand = command }
                }.accessibilityIdentifier("mole.setup.copy-command")
                Text(m("Copying only changes the clipboard. In Terminal, press ⌘V to paste the reviewed command, then press Return. Running it downloads from GitHub and writes new folders in your home directory; it never overwrites an existing installation."))
                    .foregroundStyle(.secondary)
                Text(m("Wait for this success message before continuing:"))
                    .foregroundStyle(.secondary)
                Text(verbatim: "Mole analyzer ready").font(.callout.monospaced())
                    .textSelection(.enabled)
                Text(m("If Terminal reports an error or an existing folder, stop and read the message. Existing files and the temporary download folder are kept. Try Recheck before changing anything."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            step(4, m("Return to MoeKit and recheck")) {
                Text(m(onRecheck == nil
                    ? "Open Mole → Space → Analyze with Mole…, then choose Recheck. When Ready to analyze appears, choose a folder and review the analysis."
                    : "Return here and choose Recheck. When Ready to analyze appears, choose a folder below and review the analysis."))
                    .foregroundStyle(.secondary)
                if let onRecheck {
                    Button(m(isRechecking ? "Checking installation…" : "Recheck"), action: onRecheck)
                        .disabled(isRecheckDisabled)
                        .accessibilityIdentifier("mole.setup.installation.recheck")
                }
            }
            DisclosureGroup(m("Advanced download details"), isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Asset for this app: \(release.assetName)")
                    Link("View the exact analyzer download", destination: release.assetURL)
                    Text("Expected size: \(release.byteCount) bytes")
                    Text("SHA-256: \(release.sha256)")
                    Text(m("The guided download is detected at:"))
                    Text(verbatim: "~/\(release.installationDirectoryName)/analyze-go")
                    Text(m("The official Mole script's usual analyzer location is also checked:"))
                    Text(verbatim: "~/.config/mole/bin/analyze-go")
                    Text(m("A matching path alone is not enough. MoeKit verifies the file again before every analysis."))
                }.font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }.font(.callout)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step<Content: View>(_ number: Int, _ title: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: String(number)).font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).fontWeight(.semibold)
                content()
            }.font(.callout).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func m(_ key: String) -> String { MoleSetupText.localized(key) }
}

enum MoleSetupText {
    static func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), table: "MoleSetup")
    }
}
