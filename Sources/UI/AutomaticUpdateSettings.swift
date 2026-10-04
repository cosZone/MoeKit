import SwiftUI

struct AutomaticUpdateSettings: View {
    let updates: SparkleUpdateStore
    let openManualReleases: () -> Void

    var body: some View {
        Section("Updates") {
            if updates.isStarted {
                Button("Check for updates…") { updates.check() }
                    .disabled(!updates.canCheck)
                    .installerCaptureIdentity("sparkle.check", text: String(localized: "Check for updates…"))
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updates.snapshot.checksAutomatically }, set: { updates.setAutomaticChecks($0) }))
                    .installerCaptureIdentity("sparkle.checks", text: String(localized: "Automatically check for updates"))
                Toggle("Automatically download and install updates", isOn: Binding(
                    get: { updates.snapshot.downloadsAutomatically }, set: { updates.setAutomaticDownloads($0) }))
                    .disabled(!updates.snapshot.allowsAutomaticUpdates)
                    .installerCaptureIdentity("sparkle.downloads", text: String(localized: "Automatically download and install updates"))
                Toggle("Include preview releases", isOn: Binding(
                    get: { updates.includePreviews }, set: { updates.setIncludePreviews($0) }))
                    .disabled(updates.snapshot.sessionInProgress)
                    .installerCaptureIdentity("sparkle.previews", text: String(localized: "Include preview releases"))
                Text("Sparkle verifies signed updates before installation. Automatic installation happens when MoeKit quits; you can also review and install an update now.")
                    .font(.caption).foregroundStyle(.secondary)
                    .installerCaptureIdentity("sparkle.behavior", text: "signed update behavior")
                if let date = updates.snapshot.lastChecked {
                    LabeledContent("Last checked") { Text(date, style: .relative) }
                }
            } else {
                Text(updates.failureMessage ?? String(localized: "Automatic updates are not configured in this build. Download releases from GitHub until a signed update build is available."))
                    .font(.caption).foregroundStyle(.secondary)
                    .installerCaptureIdentity("sparkle.unavailable", text: "automatic updates unavailable")
                Button("Check releases on GitHub…", action: openManualReleases)
                    .installerCaptureIdentity("sparkle.releases", text: String(localized: "Check releases on GitHub…"))
            }
            Text("Update requests go to GitHub and may include your app version and IP address. Project data and system profiling are not sent. Project lists, preferences and recovery receipts stay outside the app bundle.")
                .font(.caption).foregroundStyle(.secondary)
                .installerCaptureIdentity("sparkle.privacy", text: "update privacy and retained preferences")
        }
    }
}
