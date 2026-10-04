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
                Text("Checks public GitHub releases only when requested. GitHub receives your IP address; no project paths, task records or credentials are sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                result
                if let date = updates.checkedAt {
                    LabeledContent("Checked", value: date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check for updates…") { updates.check() }
                        .disabled(updates.isChecking)
                        .keyboardShortcut(.defaultAction)
                    if updates.isChecking {
                        Button("Cancel") { updates.cancel() }
                    }
                }
            }
            Section {
                Text("Updates are downloaded and installed manually from the release page. Automatic installation is not enabled.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("All releases on GitHub", destination: MoeKitLinks.repository.appendingPathComponent("releases"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 440)
        .onDisappear { updates.cancel() }
        .onExitCommand { updates.cancel(); dismiss() }
    }

    @ViewBuilder private var result: some View {
        switch updates.state {
        case .idle: Text("Ready to check for a newer release.")
        case .checking: ProgressView("Checking GitHub…")
        case .cancelled: Text("Update check cancelled.")
        case .noReleases: Text("No supported releases were found for this channel.")
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").textSelection(.enabled)
        case .available(let release):
            Label("A newer release is available: \(release.version.description)", systemImage: "arrow.down.circle")
            Link("View release and download", destination: release.pageURL)
        case .current(let version):
            Label("No release newer than \(version.description) was found in this channel.", systemImage: "checkmark.circle")
        case .latestForDevelopment(let release):
            Text("Latest published release: \(release.version.description)")
            Text("A development build cannot be compared with a published release.")
                .font(.caption).foregroundStyle(.secondary)
            Link("View release and download", destination: release.pageURL)
        }
    }
}
