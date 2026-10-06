import AppKit
import SwiftUI

struct AboutView: View {
    let information: AppInformation

    init(information: AppInformation = AppInformation(infoDictionary: Bundle.main.infoDictionary)) {
        self.information = information
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)

                Text("MoeKit")
                    .font(.title2.weight(.semibold))

                versionLabel
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text("Projects and tools, in one place")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Link(destination: MoeKitLinks.feedback) {
                        Label("Feedback", systemImage: "bubble.left")
                    }
                    .help("Open MoeKit’s GitHub issues in your browser")

                    Link(destination: MoeKitLinks.repository) {
                        Label("Star on GitHub", systemImage: "star")
                    }
                    .help("Open the MoeKit repository to give it a star on GitHub")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Text("Opens GitHub in your default browser")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let copyright = information.copyright {
                Text(verbatim: copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }

    @ViewBuilder
    private var versionLabel: some View {
        VStack(spacing: 3) {
            if let version = information.displayVersion {
                Text("Version \(version)")
                    .fontWeight(.medium)
                    .installerCaptureIdentity("about.version", text: String(localized: "Version \(version)"))
            } else {
                Text("Version unavailable")
                    .installerCaptureIdentity("about.version", text: String(localized: "Version unavailable"))
            }
            if let build = information.build {
                Text("Internal build \(build)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .installerCaptureIdentity("about.build", text: String(localized: "Internal build \(build)"))
            }
        }
    }
}

/// Escape closes the dedicated window without affecting the Settings About tab.
struct AboutWindowView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AboutView()
            .frame(width: 440)
            .fixedSize(horizontal: false, vertical: true)
            .onExitCommand { dismiss() }
    }
}
