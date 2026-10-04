import SwiftUI

struct AutomaticUpdateSettings: View {
    let updates: SparkleUpdateStore
    let openManualReleases: () -> Void

    var body: some View {
        Section("Updates") {
            if updates.isStarted {
                Button("Check for updates…") { updates.check() }
                    .disabled(!updates.canCheck)
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updates.snapshot.checksAutomatically }, set: updates.setAutomaticChecks))
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updates.snapshot.downloadsAutomatically }, set: updates.setAutomaticDownloads))
                    .disabled(!updates.snapshot.allowsAutomaticUpdates)
                Toggle("Include preview releases", isOn: Binding(
                    get: { updates.includePreviews }, set: updates.setIncludePreviews))
                Text("Sparkle verifies signed updates before installation. Automatic installation happens when MoeKit quits; you can also review and install an update now.")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = updates.snapshot.lastChecked {
                    LabeledContent("Last checked") { Text(date, style: .relative) }
                }
            } else {
                Text(updates.failureMessage ?? String(localized: "Automatic updates are not configured in this build. Download releases from GitHub until a signed update build is available."))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Check releases on GitHub…", action: openManualReleases)
            }
            Text("Update requests go to GitHub and may include your app version and IP address. Project data and system profiling are not sent. Project lists, preferences and recovery receipts stay outside the app bundle.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
