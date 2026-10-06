import AppKit
import SwiftUI

@main
@MainActor
struct MoeKitApp: App {
    @NSApplicationDelegateAdaptor(MoeKitAppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings
    @State private var store = WorkspaceStore(gettingStarted: GettingStartedState(defaults: .standard))
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "workspace", for: String.self) { _ in
            WorkspaceView()
                .environment(store)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear {
                    appDelegate.entryPoints.install(
                        openWorkspace: { openWindow(id: "workspace", value: "main") },
                        openSettings: { openSettings() },
                        checkUpdates: {
                            if appDelegate.automaticUpdates.isStarted {
                                appDelegate.automaticUpdates.check()
                            } else {
                                openWindow(id: "updates")
                                appDelegate.updates.check()
                            }
                        },
                        canCheckUpdates: { !appDelegate.automaticUpdates.isStarted || appDelegate.automaticUpdates.canCheck }
                    )
                }
                .task {
                    if store.showAutomaticGettingStarted() { openWindow(id: "getting-started") }
                }
        } defaultValue: { "main" }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            WorkspaceCommands()
            CommandGroup(replacing: .appInfo) {
                Button("About MoeKit") { openWindow(id: "about") }
                Button("Check for updates…") { appDelegate.entryPoints.showUpdates() }
                    .disabled(appDelegate.automaticUpdates.isStarted && !appDelegate.automaticUpdates.canCheck)
            }
            CommandGroup(replacing: .help) {
                Button("Getting started…") {
                    if store.showGettingStarted() { openWindow(id: "getting-started") }
                }.disabled(!store.canNavigateFromGettingStarted)
            }
            CommandGroup(after: .newItem) {
                Button("Open MoeKit") { appDelegate.entryPoints.showWorkspace() }
                    .keyboardShortcut("0", modifiers: [.command])
                Button("Add project…") { store.chooseProject(scanChildren: false) }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(store.isDemoEnabled || store.isScanning || store.gettingStarted.isPresented)
                Button("Discover projects…") { store.chooseProject(scanChildren: true) }
                    .disabled(store.isDemoEnabled || store.isScanning || store.gettingStarted.isPresented)
            }
        }
        Settings {
            SettingsView(checkForUpdates: {
                openWindow(id: "updates")
                appDelegate.updates.check()
            }, automaticUpdates: appDelegate.automaticUpdates)
                .environment(store)
                .environment(appDelegate.entryPoints.preferences)
        }

        Window("MoeKit updates", id: "updates") {
            ReleaseCheckView(updates: appDelegate.updates)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Window("Getting started", id: "getting-started") {
            GettingStartedWindowView().environment(store)
        }
        .defaultSize(width: 620, height: 580)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Window("Tool preparation", id: "tool-preparation") {
            ToolPreparationView(preparation: store.toolPreparation)
        }
        .defaultSize(width: 680, height: 720)
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Window("About MoeKit", id: "about") {
            AboutWindowView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct GettingStartedWindowView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        GettingStartedView(close: { dismissWindow(id: "getting-started") },
                           openWorkspace: { openWindow(id: "workspace", value: "main") })
    }
}
