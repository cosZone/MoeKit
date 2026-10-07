import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

/// Only AppKit key events may consume a prepared plan. A send callback is data,
/// not launch authority, regardless of whether it contains CR, LF or ANSI replies.
@MainActor
enum OperationTerminalKeyGate {
    static func accepts(_ event: NSEvent, hasTerminalFocus: Bool) -> Bool {
        guard hasTerminalFocus, event.type == .keyDown, !event.isARepeat,
              event.keyCode == 36 || event.keyCode == 76 else { return false }
        return event.modifierFlags.intersection([.command, .control, .option, .shift, .function]).isEmpty
    }
}

@MainActor
struct OperationTerminalRepresentable: NSViewRepresentable {
    let store: MoleUpgradeTerminalStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> TerminalView {
        let options = TerminalOptions(cols: 80, rows: 24, termName: "xterm-256color", scrollback: 2000,
                                      enableSixelReported: false, kittyImageCacheLimitBytes: 0)
        let terminal = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular), options: options)
        terminal.linkReporting = .none
        terminal.linkHighlightMode = .always // explicit-only lookup; OSC 8 is removed before feed
        terminal.allowMouseReporting = false
        terminal.terminalDelegate = context.coordinator
        terminal.setAccessibilityLabel(String(localized: "Mole upgrade terminal"))
        context.coordinator.install(terminal)
        context.coordinator.update(terminal)
        return terminal
    }
    func updateNSView(_ nsView: TerminalView, context: Context) { context.coordinator.update(nsView) }
    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.removeMonitor()
        nsView.terminalDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        private let store: MoleUpgradeTerminalStore
        private var monitor: Any?
        private var windowObservers: [NSObjectProtocol] = []
        private var isRecordingDisplay = false
        private var fedBytes = 0
        private var renderedPlanID: UUID?
        private var displayedPlanID: UUID?
        private var displayedReview: Data?
        private weak var displayedWindow: NSWindow?
        private var focusRequestedPlanID: UUID?
        private var presentationLifetime = UUID()
        private var launchKeyAwaitingRelease: UInt16?
        init(store: MoleUpgradeTerminalStore) { self.store = store }

        func install(_ terminal: TerminalView) {
            removeMonitor()
            // makeNSView/update can both precede sheet attachment. AppKit's own
            // window lifecycle provides bounded rechecks, without a polling timer.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didUpdateNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self, weak terminal] notification in
                    MainActor.assumeIsolated {
                        guard let self, let terminal, let window = notification.object as? NSWindow,
                              terminal.window === window else { return }
                        self.presentationBecameAvailable(terminal)
                    }
                })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak terminal] event in
                // AppKit invokes local event monitors on the event/main thread.
                let consume = MainActor.assumeIsolated {
                    guard let self, let terminal else { return false }
                    return self.handleKeyEvent(event, terminal: terminal)
                }
                return consume ? nil : event
            }
        }

        /// The same path used by the AppKit event monitor is exercised by native
        /// tests. Ready model state alone is never permission to launch.
        func handleKeyEvent(_ event: NSEvent, terminal: TerminalView) -> Bool {
            guard let window = terminal.window, event.window === window,
                  window.isVisible, !terminal.isHiddenOrHasHiddenAncestor,
                  window.firstResponder === terminal else { return false }
            if launchKeyAwaitingRelease == event.keyCode {
                if event.type == .keyUp { launchKeyAwaitingRelease = nil }
                return true // a held launch Return cannot answer a later prompt
            }
            guard event.type == .keyDown else { return false }
            if store.isReady {
                if OperationTerminalKeyGate.accepts(event, hasTerminalFocus: true),
                   let plan = store.plan, hasDisplayedReview(planID: plan.id, in: terminal) {
                    launchKeyAwaitingRelease = event.keyCode
                    store.handleUserReturn(planID: plan.id)
                    return true // the launch Return is never also sent to brew
                }
                // Copy and selection remain available while reviewing. An early
                // Return is consumed rather than queued while presentation catches up.
                return !event.modifierFlags.contains(.command)
            }
            return false
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
            windowObservers.removeAll()
            presentationLifetime = UUID()
            focusRequestedPlanID = nil; launchKeyAwaitingRelease = nil
            revokeDisplayReceipt()
        }
        func update(_ terminal: TerminalView) {
            if store.plan?.id != renderedPlanID || store.transcript.count < fedBytes {
                revokeDisplayReceipt()
                terminal.getTerminal().resetToInitialState(); terminal.getTerminal().clearScrollback()
                fedBytes = 0; renderedPlanID = store.plan?.id
            }
            if store.transcript.count > fedBytes {
                revokeDisplayReceipt()
                // Record the feed cursor before feed: terminal-generated responses
                // may synchronously enter send(), but cannot publish a display receipt.
                let fresh = Array(store.transcript.suffix(from: fedBytes))
                fedBytes = store.transcript.count
                terminal.feed(byteArray: fresh[...])
            }
            guard store.isReady, let plan = store.plan else {
                revokeDisplayReceipt(); focusRequestedPlanID = nil
                return
            }
            recordDisplayedReview(planID: plan.id, in: terminal)
            if focusRequestedPlanID != plan.id {
                focusRequestedPlanID = plan.id
                let lifetime = presentationLifetime
                let planID = plan.id
                let originalResponder = terminal.window?.firstResponder
                // A deferred callback must not steal focus after cancellation,
                // another review, dismissal, reparenting or a user's focus change.
                DispatchQueue.main.async { [weak self, weak terminal, weak window = terminal.window] in
                    guard let self, let terminal, self.presentationLifetime == lifetime,
                          self.store.isReady, self.store.plan?.id == planID else { return }
                    // Initial makeNSView can precede attachment. It may establish
                    // presentation once attached, but cannot assume focus authority.
                    self.recordDisplayedReview(planID: planID, in: terminal)
                    guard let window, terminal.window === window, window.isKeyWindow,
                          window.isVisible, window.firstResponder === originalResponder,
                          self.hasDisplayedReview(planID: planID, in: terminal) else { return }
                    window.makeFirstResponder(terminal)
                }
            }
        }
        private func revokeDisplayReceipt() {
            displayedPlanID = nil; displayedReview = nil; displayedWindow = nil
        }
        private func presentationBecameAvailable(_ terminal: TerminalView) {
            guard store.isReady, let plan = store.plan,
                  !hasDisplayedReview(planID: plan.id, in: terminal) else { return }
            // This only completes presentation of bytes already fed by update().
            // It never consumes a plan or changes the user's first responder.
            recordDisplayedReview(planID: plan.id, in: terminal)
        }
        private func recordDisplayedReview(planID: UUID, in terminal: TerminalView) {
            guard !isRecordingDisplay, store.isReady, let plan = store.plan, plan.id == planID,
                  renderedPlanID == planID, let window = terminal.window,
                  window.isVisible, !terminal.isHiddenOrHasHiddenAncestor,
                  !terminal.visibleRect.isEmpty else { return }
            let review = Data(plan.reviewText.utf8)
            guard fedBytes == review.count, store.transcript == review else { return }
            isRecordingDisplay = true
            defer { isRecordingDisplay = false }
            terminal.layoutSubtreeIfNeeded()
            // SwiftTerm normally coalesces feed repaint for a later frame. Force
            // this fixed review to draw before publishing the launch receipt.
            terminal.needsDisplay = true
            terminal.displayIfNeeded()
            // Publish only after the entire current review has finished feed and
            // display. The key monitor also checks this exact plan/window/byte receipt.
            guard store.isReady, store.plan?.id == planID, terminal.window === window,
                  window.isVisible, store.transcript == review, fedBytes == review.count else { return }
            displayedPlanID = planID; displayedReview = review; displayedWindow = window
        }
        private func hasDisplayedReview(planID: UUID, in terminal: TerminalView) -> Bool {
            guard store.isReady, let plan = store.plan, plan.id == planID,
                  renderedPlanID == planID, displayedPlanID == planID,
                  let window = terminal.window, displayedWindow === window,
                  window.isVisible, !terminal.isHiddenOrHasHiddenAncestor,
                  let displayedReview, displayedReview == store.transcript,
                  displayedReview == Data(plan.reviewText.utf8), fedBytes == displayedReview.count else { return false }
            return true
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { store.resize(columns: newCols, rows: newRows) }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { store.send(Data(data)) }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
