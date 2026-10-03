import SwiftUI

@main
@MainActor
struct MoeKitApp: App {
    @State private var store = WorkspaceStore()

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environment(store)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add project…") { store.chooseProject(scanChildren: false) }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(store.isDemoEnabled || store.isScanning)
                Button("Discover projects…") { store.chooseProject(scanChildren: true) }
                    .disabled(store.isDemoEnabled || store.isScanning)
            }
        }
        Settings { SettingsView().environment(store) }
    }
}
