import AppKit
import Observation
import SwiftUI

/// Owns one status item and one transient, SwiftUI-hosted native popover.
/// No private API, process-wide click swallowing, polling, or idle animation.
@MainActor
final class MoeMenuBarController: NSObject, NSPopoverDelegate {
    let statusItem: NSStatusItem
    let presentation = MenuBarPresentation()
    private(set) var isAnimating = false
    private(set) var isInstalled = true
    private(set) var popover: NSPopover
    private var animation: Task<Void, Never>?
    private var animationGeneration = UUID()
    private var observationGeneration = UUID()
    private var clickMonitor: Any?
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    private var images: [String: NSImage] = [:]
    private let reduceMotion: () -> Bool
    private let makeMenu: () -> NSMenu
    private let canCheckUpdates: () -> Bool

    init(openWorkspace: @escaping () -> Void, openSettings: @escaping () -> Void,
         checkUpdates: @escaping () -> Void, quit: @escaping () -> Void,
         makeMenu: @escaping () -> NSMenu, canCheckUpdates: @escaping () -> Bool,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         observeSystem: Bool = true) {
        self.makeMenu = makeMenu
        self.canCheckUpdates = canCheckUpdates
        self.reduceMotion = reduceMotion
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        super.init()
        let panel = MenuBarPanelView(presentation: presentation,
            openWorkspace: openWorkspace, openSettings: openSettings,
            checkUpdates: checkUpdates, quit: quit, close: { [weak self] in self?.closePanel() })
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.contentSize = MenuBarPanelView.size
        popover.behavior = .transient
        popover.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(activateItem)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("MoeKit")
            button.setAccessibilityHelp(MenuBarText.localized("Open the quick panel"))
        }
        refreshAppearance()
        if observeSystem { installSystemObservers() }
    }

    func bind(to store: WorkspaceStore) {
        observationGeneration = UUID()
        observe(store, generation: observationGeneration)
    }

    private func observe(_ store: WorkspaceStore, generation: UUID) {
        guard isInstalled, generation == observationGeneration else { return }
        withObservationTracking {
            let snapshot = store.menuBarSnapshot
            let updatesAvailable = canCheckUpdates()
            update(snapshot)
            presentation.canCheckUpdates = updatesAvailable
        } onChange: { [weak self, weak store] in
            // Observation reports before the mutation. Read on the next main
            // actor turn, rearming even while the panel/workspace is hidden.
            Task { @MainActor [weak self, weak store] in
                guard let self, let store, self.isInstalled,
                      self.observationGeneration == generation else { return }
                self.observe(store, generation: generation)
            }
        }
    }

    func update(_ snapshot: MenuBarSnapshot) {
        guard snapshot != presentation.snapshot else { return }
        presentation.snapshot = snapshot
        // A state/mode boundary cannot leave an old frame/badge onscreen.
        stopAnimation()
        refreshAppearance()
    }

    func refreshAppearance() {
        guard isInstalled else { return }
        if reduceMotion() { stopAnimation() }
        popover.animates = !reduceMotion()
        presentation.canCheckUpdates = canCheckUpdates()
        statusItem.button?.toolTip = "MoeKit · \(presentation.snapshot.activity.title)"
        statusItem.button?.setAccessibilityValue(presentation.snapshot.activity.title)
        drawFrame(0)
    }

    private func drawFrame(_ frame: Int) {
        let kind = presentation.snapshot.activity
        let key = "\(kind.rawValue)-\(frame)"
        if images[key] == nil { images[key] = MenuBarIcon.image(activity: kind, frame: frame) }
        statusItem.button?.image = images[key]
    }

    /// Only explicit pointer activation plays this bounded response. Work-in-
    /// progress is a still clock badge; completed/attention also remain still.
    func playResponse() {
        guard isInstalled, !isAnimating, !reduceMotion() else { return }
        isAnimating = true
        animationGeneration = UUID()
        let generation = animationGeneration
        animation = Task { @MainActor [weak self] in
            for frame in 1..<MenuBarIcon.frameCount {
                guard let self, self.isInstalled, !Task.isCancelled,
                      self.animationGeneration == generation else { return }
                if self.reduceMotion() { self.stopAnimation(); return }
                self.drawFrame(frame)
                do { try await Task.sleep(for: .milliseconds(MenuBarIcon.frameMilliseconds)) }
                catch { return }
            }
            guard let self, self.animationGeneration == generation else { return }
            self.animation = nil
            self.isAnimating = false
            self.drawFrame(0)
        }
    }

    func stopAnimation() {
        animationGeneration = UUID()
        animation?.cancel()
        animation = nil
        isAnimating = false
        if isInstalled { drawFrame(0) }
    }

    @objc private func activateItem() {
        guard isInstalled else { return }
        let event = NSApp.currentEvent
        guard event?.modifierFlags.contains(.command) != true else { return }
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePanel(animate: event?.type == .leftMouseUp)
        }
    }

    func togglePanel(animate: Bool = false) {
        guard isInstalled else { return }
        if popover.isShown { closePanel(); return }
        guard let button = statusItem.button, button.window != nil else { return }
        refreshAppearance()
        if animate { playResponse() }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePanel() {
        if popover.isShown { popover.performClose(nil) }
        statusItem.button?.highlight(false)
        stopAnimation()
    }

    func popoverDidClose(_ notification: Notification) { closePanel() }

    private func showContextMenu() {
        closePanel()
        guard let button = statusItem.button else { return }
        button.highlight(true)
        defer { button.highlight(false) }
        let menu = makeMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    /// Intercept only this owned button's plain mouse-down. Otherwise AppKit's
    /// mouse-up tracking briefly clears the open-panel highlight. Command
    /// gestures stay entirely with the system, including menu-bar rearranging.
    private func installSystemObservers() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            // NSEvent must never cross an isolation boundary as the result.
            // AppKit delivers local monitors on the main thread; return only
            // the Sendable decision and keep the event in this callback.
            let consumed = MainActor.assumeIsolated { self?.consumeOwnedEvent(event) ?? false }
            return consumed ? nil : event
        }
        listen(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in
            self?.refreshAppearance()
        }
        listen(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { [weak self] in self?.closePanel() }
        listen(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.closePanel() }
        listen(.default, NSApplication.didResignActiveNotification) { [weak self] in self?.closePanel() }
    }

    private func consumeOwnedEvent(_ event: NSEvent) -> Bool {
        guard isInstalled else { return false }
        if event.type == .keyDown {
            if popover.isShown, event.window === popover.contentViewController?.view.window,
               event.keyCode == 53 { closePanel(); return true }
            return false
        }
        guard !event.modifierFlags.contains(.command),
              let button = statusItem.button, event.window === button.window,
              button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return false }
        if event.modifierFlags.contains(.control) { showContextMenu() }
        else { togglePanel(animate: true) }
        return true
    }

    private func listen(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        notifications.append((center, token))
    }

    func uninstall() {
        guard isInstalled else { return }
        closePanel()
        isInstalled = false
        observationGeneration = UUID()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        for (center, token) in notifications { center.removeObserver(token) }
        notifications.removeAll()
        popover.delegate = nil
        popover.contentViewController = nil
        statusItem.button?.target = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        images.removeAll()
    }
}

/// Keep the real workspace in the Space where it is reopened. AppKit handles
/// ordinary/full-screen window closure; the shared model outlives the window.
struct WorkspaceWindowPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> PlacementView { PlacementView() }
    func updateNSView(_ nsView: PlacementView, context: Context) {}

    final class PlacementView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenPrimary])
        }
    }
}
