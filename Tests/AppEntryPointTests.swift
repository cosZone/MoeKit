import AppKit
import Testing
@testable import MoeKit

@MainActor
struct AppEntryPointTests {
    @Test func independentPreferencesPersistAllCombinationsWithoutOtherWrites() throws {
        let name = "MoeKit-icons-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppVisibilityPreferences(defaults: defaults)
        #expect(preferences.showDockIcon && preferences.showMenuBarIcon)
        #expect(defaults.persistentDomain(forName: name) == nil)
        for dock in [false, true] {
            for menu in [false, true] {
                preferences.showDockIcon = dock
                preferences.showMenuBarIcon = menu
                let relaunched = AppVisibilityPreferences(defaults: defaults)
                #expect(relaunched.showDockIcon == dock && relaunched.showMenuBarIcon == menu)
                #expect(relaunched.hasNoPersistentIcon == (!dock && !menu))
                #expect(defaults.persistentDomain(forName: name)?.count == 2)
            }
        }
    }

    @Test func reopenRoutesBeforeInstallationAndAfterWindowClose() {
        let preferences = AppVisibilityPreferences()
        var policies: [Bool] = []
        var opens = 0, settings = 0, updates = 0, quits = 0, activations = 0
        let controller = AppEntryPointController(preferences: preferences, managesStatusItem: false,
            applyDock: { policies.append($0) }, activate: { activations += 1 }, quit: { quits += 1 })
        controller.showWorkspace()
        #expect(opens == 0 && policies.isEmpty)
        controller.install(openWorkspace: { opens += 1 }, openSettings: { settings += 1 }, checkUpdates: { updates += 1 })
        #expect(opens == 1 && policies == [true])
        preferences.showDockIcon = false
        preferences.showMenuBarIcon = false
        #expect(preferences.hasNoPersistentIcon)
        controller.showWorkspace(); controller.showWorkspace()
        controller.showSettings(); controller.showUpdates()
        #expect(opens == 3 && settings == 1 && updates == 1 && quits == 0)
        #expect(policies == [true, false, false])
        #expect(activations >= 6)
        controller.quitApp()
        #expect(quits == 1)
    }

    @Test func nativeMenuUsesExplicitTargetsAndKeyboardEquivalents() throws {
        _ = NSApplication.shared
        var opens = 0, settings = 0, updates = 0, quits = 0
        let controller = AppEntryPointController(preferences: AppVisibilityPreferences(), managesStatusItem: false,
            applyDock: { _ in }, activate: {}, quit: { quits += 1 })
        controller.install(openWorkspace: { opens += 1 }, openSettings: { settings += 1 }, checkUpdates: { updates += 1 })
        let menu = controller.makeMenu()
        #expect(menu.items.count == 5)
        #expect(menu.items.map(\.keyEquivalent) == ["o", ",", "", "", "q"])
        for index in [0, 1, 2, 4] {
            let item = menu.items[index]
            #expect(item.isEnabled && item.target === controller)
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
        #expect(opens == 1 && settings == 1 && updates == 1 && quits == 1)
        for (key, code) in [("o", UInt16(31)), (",", UInt16(43)), ("q", UInt16(12))] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(menu.performKeyEquivalent(with: event))
        }
        #expect(opens == 2 && settings == 2 && updates == 1 && quits == 2)
    }

    @Test func delegateReopenKeepsAppAliveAfterClosingAllWindows() {
        _ = NSApplication.shared
        let preferences = AppVisibilityPreferences()
        preferences.showDockIcon = false; preferences.showMenuBarIcon = false
        var opens = 0
        let controller = AppEntryPointController(preferences: preferences, managesStatusItem: false,
            applyDock: { _ in }, activate: {}, quit: {})
        let updates = ReleaseCheckStore(installedVersion: nil)
        let delegate = MoeKitAppDelegate(entryPoints: controller, updates: updates)
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        controller.install(openWorkspace: { opens += 1 }, openSettings: {}, checkUpdates: {})
        #expect(opens == 1)
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        #expect(opens == 3 && preferences.hasNoPersistentIcon)
        #expect(updates.state == .idle)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(!controller.isInstalled)
    }

    @Test func ownedStatusItemIsInsertedRemovedAndRecreated() {
        _ = NSApplication.shared
        let preferences = AppVisibilityPreferences()
        let controller = AppEntryPointController(preferences: preferences, applyDock: { _ in }, activate: {}, quit: {})
        defer { controller.uninstall() }
        controller.install(openWorkspace: {}, openSettings: {}, checkUpdates: {})
        #expect(controller.statusItem?.menu == nil)
        #expect(controller.statusItem?.button?.target === controller.menuBar)
        #expect(controller.statusItem?.button?.image?.isTemplate == true)
        let first = controller.statusItem
        controller.install(openWorkspace: {}, openSettings: {}, checkUpdates: {})
        #expect(controller.statusItem === first)
        preferences.showMenuBarIcon = false
        #expect(controller.statusItem == nil && preferences.showDockIcon)
        preferences.showDockIcon = false
        preferences.showMenuBarIcon = true
        #expect(controller.statusItem != nil && !preferences.showDockIcon)
        #expect(controller.statusItem !== first)
    }
}
