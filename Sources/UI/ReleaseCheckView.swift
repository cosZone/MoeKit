import SwiftUI

struct ReleaseCheckView: View {
    @Bindable var updates: ReleaseCheckStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("MoeKit updates") {
                if let installed = updates.installedVersion {
                    LabeledContent("Installed release", value: installed.description)
                } else {
                    Text("This development build has no published release identity.")
                        .foregroundStyle(.secondary)
                }
                Toggle("Include preview releases", isOn: $updates.includePreviews)
                    .installerCaptureIdentity("updates.channel", text: String(localized: "Include preview releases"))
                Text("Checks public GitHub releases only when requested. GitHub receives your IP address; no project paths, task records or credentials are sent.")
                    .font(.caption).foregroundStyle(.secondary)
                    .installerCaptureIdentity("updates.privacy", text: String(localized: "Checks public GitHub releases only when requested. GitHub receives your IP address; no project paths, task records or credentials are sent."))
            }
            Section {
                VStack(alignment: .leading, spacing: 8) { result }
                if let date = updates.checkedAt {
                    LabeledContent("Checked", value: date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check for updates…") { updates.check() }
                        .disabled(updates.isChecking)
                        .keyboardShortcut(.defaultAction)
                        .installerCaptureIdentity("updates.check", text: String(localized: "Check for updates…"))
                    if updates.isChecking {
                        Button("Cancel") { updates.cancel() }
                    }
                }
            }
            Section {
                Text("Updates are downloaded and installed manually from the release page. Automatic installation is not enabled.")
                    .font(.caption).foregroundStyle(.secondary)
                    .installerCaptureIdentity("updates.installation", text: String(localized: "Updates are downloaded and installed manually from the release page. Automatic installation is not enabled."))
                Link("All releases on GitHub", destination: MoeKitLinks.repository.appendingPathComponent("releases"))
                    .installerCaptureIdentity("updates.releases", text: "GitHub release navigation")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 520)
        .onDisappear { updates.cancel() }
        .onExitCommand { updates.cancel(); dismiss() }
    }

    @ViewBuilder private var result: some View {
        switch updates.state {
        case .idle: Text("Ready to check for a newer release.")
                .installerCaptureIdentity("updates.result", text: "Release check result")
        case .checking: ProgressView("Checking GitHub…")
                .installerCaptureIdentity("updates.result", text: "Release check result")
        case .cancelled: Text("Update check cancelled.")
                .installerCaptureIdentity("updates.result", text: "Release check result")
        case .noReleases: Text("No supported releases were found for this channel.")
                .installerCaptureIdentity("updates.result", text: "Release check result")
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                .installerCaptureIdentity("updates.result", text: "Release check result")
        case .available(let release):
            Label("A newer release is available: \(release.version.description)", systemImage: "arrow.down.circle")
                .installerCaptureIdentity("updates.result", text: "Release check result")
            Link("View release and download", destination: release.pageURL)
                .installerCaptureIdentity("updates.download", text: String(localized: "View release and download"))
        case .current(let version):
            Label("No release newer than \(version.description) was found in this channel.", systemImage: "checkmark.circle")
                .installerCaptureIdentity("updates.result", text: "Release check result")
        case .latestForDevelopment(let release):
            Text("Latest published release: \(release.version.description)")
                .installerCaptureIdentity("updates.result", text: "Release check result")
            Text("A development build cannot be compared with a published release.")
                .font(.caption).foregroundStyle(.secondary)
            Link("View release and download", destination: release.pageURL)
                .installerCaptureIdentity("updates.download", text: String(localized: "View release and download"))
        }
    }
}
