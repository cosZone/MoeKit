import AppKit
import Observation

/// Preferences are independent; no implicit toggle changes another user choice.
@MainActor @Observable
final class AppVisibilityPreferences {
    static let dockKey = "MoeKit.showDockIcon"
    static let menuBarKey = "MoeKit.showMenuBarIcon"
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored var didChange: (() -> Void)?

    var showDockIcon: Bool { didSet { save(showDockIcon, key: Self.dockKey) } }
    var showMenuBarIcon: Bool { didSet { save(showMenuBarIcon, key: Self.menuBarKey) } }
    var hasNoPersistentIcon: Bool { !showDockIcon && !showMenuBarIcon }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        showDockIcon = defaults?.object(forKey: Self.dockKey) as? Bool ?? true
        showMenuBarIcon = defaults?.object(forKey: Self.menuBarKey) as? Bool ?? true
    }

    private func save(_ value: Bool, key: String) {
        defaults?.set(value, forKey: key)
        didChange?()
    }
}

/// App-owned routing outlives workspace windows. Closing a window never
/// destroys the shared WorkspaceStore. Individual views retain their existing
/// cancellation/revocation rules when a window closes.
@MainActor
final class AppEntryPointController: NSObject {
    let preferences: AppVisibilityPreferences
    private(set) var statusItem: NSStatusItem?
    private(set) var isInstalled = false
    private var openWorkspace: (() -> Void)?
    private var openSettings: (() -> Void)?
    private var checkUpdates: (() -> Void)?
    private var pendingReopen = false
    private let applyDock: (Bool) -> Void
    private let activate: () -> Void
    private let quit: () -> Void
    private let managesStatusItem: Bool

    init(preferences: AppVisibilityPreferences,
         managesStatusItem: Bool = true,
         applyDock: @escaping (Bool) -> Void = { NSApp.setActivationPolicy($0 ? .regular : .accessory) },
         activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) },
         quit: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.preferences = preferences
        self.managesStatusItem = managesStatusItem
        self.applyDock = applyDock
        self.activate = activate
        self.quit = quit
        super.init()
        preferences.didChange = { [weak self] in self?.applyPreferences() }
    }

    func install(openWorkspace: @escaping () -> Void, openSettings: @escaping () -> Void,
                 checkUpdates: @escaping () -> Void) {
        self.openWorkspace = openWorkspace
        self.openSettings = openSettings
        self.checkUpdates = checkUpdates
        if !isInstalled {
            isInstalled = true
            applyPreferences()
        }
        if pendingReopen { pendingReopen = false; showWorkspace() }
    }

    func applyPreferences() {
        guard isInstalled else { return }
        applyDock(preferences.showDockIcon)
        if managesStatusItem {
            if preferences.showMenuBarIcon && statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "MoeKit")
                item.button?.image?.isTemplate = true
                item.button?.toolTip = "MoeKit"
                item.menu = makeMenu()
                statusItem = item
            } else if !preferences.showMenuBarIcon, let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
        // Keep the settings window usable when switching to an accessory app.
        activate()
    }

    func uninstall() {
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        isInstalled = false
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "MoeKit")
        menu.autoenablesItems = false
        for (title, action, key) in [
            (String(localized: "Open MoeKit"), #selector(showWorkspace), "o"),
            (String(localized: "Settings…"), #selector(showSettings), ","),
            (String(localized: "Check for updates…"), #selector(showUpdates), "")
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
        }
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: String(localized: "Quit MoeKit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        return menu
    }

    @objc func showWorkspace() {
        guard let openWorkspace else { pendingReopen = true; return }
        openWorkspace()
        activate()
    }
    @objc func showSettings() { openSettings?(); activate() }
    @objc func showUpdates() { checkUpdates?(); activate() }
    @objc func quitApp() { quit() }
}

@MainActor
final class MoeKitAppDelegate: NSObject, NSApplicationDelegate {
    let entryPoints = AppEntryPointController(preferences: AppVisibilityPreferences(defaults: .standard))
    let updates = ReleaseCheckStore()

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopen the workspace even if only Settings or About is currently visible.
        entryPoints.showWorkspace()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { updates.cancel(); entryPoints.uninstall() }
}
