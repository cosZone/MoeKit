import SwiftUI

@main
@MainActor
struct MoeKitApp: App {
    @State private var store = WorkspaceStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environment(store)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MoeKit") { openWindow(id: "about") }
            }
            CommandGroup(after: .newItem) {
                Button("Add project…") { store.chooseProject(scanChildren: false) }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(store.isDemoEnabled || store.isScanning)
                Button("Discover projects…") { store.chooseProject(scanChildren: true) }
                    .disabled(store.isDemoEnabled || store.isScanning)
            }
        }
        Settings { SettingsView().environment(store) }

        Window("About MoeKit", id: "about") {
            AboutWindowView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
    }
}
