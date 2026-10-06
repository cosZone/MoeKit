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
final class AppEntryPointController: NSObject, NSMenuDelegate {
    let preferences: AppVisibilityPreferences
    var statusItem: NSStatusItem? { menuBar?.statusItem }
    private(set) var menuBar: MoeMenuBarController?
    private weak var workspace: WorkspaceStore?
    private(set) var isInstalled = false
    private var openWorkspace: (() -> Void)?
    private var openSettings: (() -> Void)?
    private var checkUpdates: (() -> Void)?
    private var canCheckUpdates: () -> Bool = { true }
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
                 checkUpdates: @escaping () -> Void, canCheckUpdates: @escaping () -> Bool = { true }) {
        self.openWorkspace = openWorkspace
        self.openSettings = openSettings
        self.checkUpdates = checkUpdates
        self.canCheckUpdates = canCheckUpdates
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
                let controller = MoeMenuBarController(
                    openWorkspace: { [weak self] in self?.showWorkspace() },
                    openSettings: { [weak self] in self?.showSettings() },
                    checkUpdates: { [weak self] in self?.showUpdates() },
                    quit: { [weak self] in self?.quitApp() },
                    makeMenu: { [weak self] in self?.makeMenu() ?? NSMenu() },
                    canCheckUpdates: { [weak self] in self?.canCheckUpdates() ?? false })
                menuBar = controller
                if let workspace { controller.bind(to: workspace) }
            } else if !preferences.showMenuBarIcon {
                menuBar?.uninstall()
                menuBar = nil
            }
        }
        // Keep the settings window usable when switching to an accessory app.
        activate()
    }

    func bindWorkspace(_ store: WorkspaceStore) {
        guard workspace !== store else { return }
        workspace = store
        menuBar?.bind(to: store)
    }

    func uninstall() {
        menuBar?.uninstall()
        menuBar = nil
        isInstalled = false
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "MoeKit")
        menu.autoenablesItems = false
        menu.delegate = self
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first(where: { $0.action == #selector(showUpdates) })?.isEnabled = canCheckUpdates()
    }

    @objc func showWorkspace() {
        guard let openWorkspace else { pendingReopen = true; return }
        menuBar?.closePanel()
        openWorkspace()
        activate()
    }
    @objc func showSettings() { menuBar?.closePanel(); openSettings?(); activate() }
    @objc func showUpdates() { guard canCheckUpdates() else { return }; menuBar?.closePanel(); checkUpdates?(); activate() }
    @objc func quitApp() { menuBar?.closePanel(); quit() }
}

@MainActor
final class MoeKitAppDelegate: NSObject, NSApplicationDelegate {
    let entryPoints: AppEntryPointController
    let updates: ReleaseCheckStore
    let automaticUpdates: SparkleUpdateStore
    private let mayTerminate: () -> Bool
    private let presentBusyAlert: () -> Void

    override convenience init() {
        self.init(entryPoints: AppEntryPointController(preferences: AppVisibilityPreferences(defaults: .standard)),
                  updates: ReleaseCheckStore())
    }

    init(entryPoints: AppEntryPointController, updates: ReleaseCheckStore, automaticUpdates: SparkleUpdateStore? = nil,
         mayTerminate: (() -> Bool)? = nil, presentBusyAlert: (() -> Void)? = nil) {
        self.entryPoints = entryPoints
        self.updates = updates
        self.automaticUpdates = automaticUpdates ?? SparkleUpdateStore()
        self.mayTerminate = mayTerminate ?? { UpdateInstallationSafety.shared.canTerminate }
        self.presentBusyAlert = presentBusyAlert ?? {
            let alert = NSAlert()
            alert.messageText = String(localized: "MoeKit is finishing an operation")
            alert.informativeText = String(localized: "Wait for the current operation to finish before quitting or installing an update.")
            alert.runModal()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) { automaticUpdates.start() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopen the workspace even if only Settings or About is currently visible.
        entryPoints.showWorkspace()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mayTerminate() else {
            presentBusyAlert()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { updates.cancel(); entryPoints.uninstall() }
}
