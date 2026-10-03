import AppKit
import SwiftUI

struct AboutView: View {
    private let information = AppInformation(infoDictionary: Bundle.main.infoDictionary)

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

                Text("A native home for your personal CLI toolbox")
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
                        Label("Give a Star", systemImage: "star")
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
        switch (information.version, information.build) {
        case let (.some(version), .some(build)):
            Text("Version \(version) (\(build))")
        case let (.some(version), .none):
            Text("Version \(version)")
        case let (.none, .some(build)):
            Text("Build \(build)")
        case (.none, .none):
            Text("Version unavailable")
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
