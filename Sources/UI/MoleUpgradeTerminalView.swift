import AppKit
import SwiftUI

struct MoleUpgradeTerminalView: View {
    @Bindable var store: MoleUpgradeTerminalStore
    let onClose: () -> Void
    @State private var closeWhenSettled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Upgrade Mole", systemImage: "terminal").font(.title2.bold())
                Spacer()
                Text(statusTitle).font(.callout).foregroundStyle(.secondary)
            }
            if let plan = store.plan {
                HStack(spacing: 20) {
                    LabeledContent("Installed version", value: safeVersion(plan.currentVersion ?? String(localized: "Unknown")))
                    LabeledContent("Recommended version", value: safeVersion(plan.recommendedVersion))
                }.font(.callout)
                Text("This first updates Homebrew's metadata and Homebrew itself, then upgrades the Mole formula and any required dependencies. It uses your existing Homebrew installation and your user account, without sudo.")
                    .font(.callout)
                Text("Homebrew may install a newer version than the recommendation. This does not pin a version or downgrade Mole. Cancelling can leave partial changes; MoeKit does not retry or roll them back.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(plan.executable.path).font(.caption.monospaced()).textSelection(.enabled)
            }
            OperationTerminalRepresentable(store: store)
                .frame(minHeight: 280)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel(Text("Mole upgrade terminal"))
            if store.isReady {
                Label("Click inside the terminal and press Return to run the displayed commands", systemImage: "return")
                    .font(.callout.bold())
            } else if let outcome = store.outcome {
                Text(outcome.message).font(.callout).textSelection(.enabled)
            } else if store.phase == .cancelling {
                Text("Stopping the owned operation and waiting for its processes to settle…").font(.callout)
            }
            if store.inputRejected {
                Text("That input was not sent. The command may not be ready for input, or the input was too large.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if let plan = store.plan {
                    Button("Copy commands") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plan.commands.joined(separator: "\n"), forType: .string)
                    }
                }
                Spacer()
                if store.phase == .running {
                    Button("Send Ctrl-C") { store.send(Data([3])) }
                    Button("Stop operation", role: .destructive) { store.cancel() }
                }
                Button(store.isBusy ? String(localized: "Stop and close") : String(localized: "Close")) {
                    closeWhenSettled = true
                    store.cancel()
                    if !store.isBusy { onClose() }
                }
                .disabled(store.phase == .cancelling)
            }
        }
        .padding(22)
        .frame(minWidth: 740, idealWidth: 840, minHeight: 650)
        .interactiveDismissDisabled(store.isBusy)
        .onChange(of: store.isBusy) { _, busy in
            if !busy && closeWhenSettled { onClose() }
        }
        .onDisappear { store.cancel() }
    }

    private var statusTitle: String {
        switch store.phase {
        case .idle, .preparing: String(localized: "Preparing review")
        case .ready: String(localized: "Waiting for Return")
        case .running: String(localized: "Operation running")
        case .cancelling: String(localized: "Stopping")
        case .finished(.completed): String(localized: "Finished; recheck required")
        case .finished: String(localized: "Operation ended")
        }
    }
    private func safeVersion(_ value: String) -> String {
        value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80).map(String.init).joined()
    }
}
