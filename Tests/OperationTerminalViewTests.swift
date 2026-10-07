import AppKit
import Foundation
import SwiftUI
@preconcurrency import SwiftTerm
import XCTest
@testable import MoeKit

final class OperationTerminalViewTests: XCTestCase {
    @MainActor
    func testUpgradeTerminalStatesRender() async throws {
        _ = NSApplication.shared
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        for state in ["pending", "active", "success", "failure", "cancel"] {
            for dark in [false, true] {
                let fixture = OperationTerminalFixture()
                let store = MoleUpgradeTerminalStore(executor: fixture)
                store.prepare(source: .appleSiliconHomebrew, currentVersion: "1.50.0", recommendedVersion: "1.58.0")
                try await wait { store.isReady }
                let plan = try XCTUnwrap(store.plan)
                if state != "pending" {
                    store.handleUserReturn(planID: plan.id)
                    await fixture.waitForStart()
                    switch state {
                    case "success": await fixture.complete(.completed)
                    case "failure": await fixture.complete(.failed(step: "update", exitCode: 7, signal: nil))
                    case "cancel": store.cancel(); await fixture.complete(.cancelled)
                    default: break
                    }
                    if state != "active" { try await wait { !store.isBusy } }
                }
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let size = NSSize(width: 900, height: 760)
                let view = MoleUpgradeTerminalView(store: store, onClose: {})
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale.current)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size); host.appearance = appearance
                let window = OperationTerminalCaptureWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = host
                window.orderFront(nil)
                for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
                XCTAssertEqual(host.bounds.size, size)
                let terminal = try XCTUnwrap(findTerminal(in: host))
                XCTAssertGreaterThan(terminal.bounds.height, 250)
                XCTAssertGreaterThan(terminal.bounds.width, 700)
                XCTAssertNil((terminal.terminalDelegate as? OperationTerminalRepresentable.Coordinator)?.clipboardRead(source: terminal))
                XCTAssertEqual(terminal.linkReporting, .none)
                // Feeding terminal replies and paste-like bytes never starts the pending plan.
                terminal.feed(text: "\u{1b}[6n")
                terminal.terminalDelegate?.send(source: terminal, data: Array("\r\n".utf8)[...])
                if state == "pending" { let starts = await fixture.starts; XCTAssertEqual(starts, 0) }
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = "mole-upgrade-\(state)-\(language)-\(dark ? "dark" : "light")-900x760"
                let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                image.name = name + ".png"; image.lifetime = .keepAlways; add(image)
                XCTAssertGreaterThan(png.count, 1000)
                let scope = XCTAttachment(string: """
                State: \(state)
                Bundle language: \(language)
                Process locale: \(Locale.current.identifier)
                Projects title: \(WorkspaceSection.projects.title)
                Partial-result title: \(TaskStatus.partial.title)
                Content size: 900 × 760 points
                Real processes launched: 0
                Actual SwiftTerm TerminalView bounds: \(terminal.bounds)
                Fixed commands: \(plan.commands.joined(separator: "; "))
                Native Homebrew/Mole mutation: none
                These are synthetic native renderer fixtures, not a real upgrade or keyboard/VoiceOver acceptance claim.
                """)
                scope.name = name + "-scope.txt"; scope.lifetime = .keepAlways; add(scope)
                window.orderOut(nil); window.contentView = nil; window.close()
                if state == "active" { store.cancel(); await fixture.complete(.cancelled); try await wait { !store.isBusy } }
            }
        }
    }

    @MainActor
    func testPendingOutputAndDelegateCannotAuthorizeExecution() async throws {
        let fixture = OperationTerminalFixture()
        let store = MoleUpgradeTerminalStore(executor: fixture)
        store.prepare(source: .appleSiliconHomebrew, currentVersion: "1.50.0", recommendedVersion: "1.58.0")
        try await wait { store.isReady }
        let coordinator = OperationTerminalRepresentable.Coordinator(store: store)
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        terminal.terminalDelegate = coordinator
        coordinator.update(terminal)
        terminal.feed(text: "\r\n\u{1b}[6n\u{1b}]52;c;?\u{7}\u{1b}]52;c;ZmFrZQ==\u{7}")
        coordinator.send(source: terminal, data: Array("\r\n".utf8)[...])
        terminal.insertText("\n", replacementRange: NSRange(location: 0, length: 0))
        coordinator.clipboardCopy(source: terminal, content: Data("untrusted".utf8))
        XCTAssertNil(coordinator.clipboardRead(source: terminal))
        coordinator.requestOpenLink(source: terminal, link: "file:///Synthetic/never-open", params: [:])
        let starts = await fixture.starts
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(store.isReady)
        store.cancel()
    }

    @MainActor
    func testReturnRequiresTheCurrentReviewToFinishDisplaying() async throws {
        _ = NSApplication.shared
        let fixture = OperationTerminalFixture()
        let store = MoleUpgradeTerminalStore(executor: fixture)
        let coordinator = OperationTerminalRepresentable.Coordinator(store: store)
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let window = OperationTerminalCaptureWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        terminal.terminalDelegate = coordinator
        coordinator.install(terminal)
        defer { coordinator.removeMonitor(); window.orderOut(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))

        store.prepare(source: .appleSiliconHomebrew, currentVersion: "1.50.0", recommendedVersion: "1.58.0")
        try await wait { store.isReady }
        XCTAssertTrue(coordinator.handleKeyEvent(enter, terminal: terminal))
        let beforeFirstDisplay = await fixture.starts
        XCTAssertEqual(beforeFirstDisplay, 0)
        XCTAssertTrue(store.isReady) // ready alone, before update(), cannot authorize execution

        coordinator.update(terminal)
        let oldPlanID = try XCTUnwrap(store.plan?.id)
        store.cancel()
        store.prepare(source: .appleSiliconHomebrew, currentVersion: "1.50.0", recommendedVersion: "1.58.0")
        try await wait { store.isReady }
        XCTAssertNotEqual(store.plan?.id, oldPlanID)
        // The new review intentionally has identical bytes and length. Its UUID
        // still differs, and the old display receipt cannot authorize it.
        XCTAssertTrue(coordinator.handleKeyEvent(enter, terminal: terminal))
        let beforeNewDisplay = await fixture.starts
        XCTAssertEqual(beforeNewDisplay, 0)
        XCTAssertTrue(store.isReady)

        coordinator.update(terminal)
        XCTAssertTrue(coordinator.handleKeyEvent(enter, terminal: terminal))
        await fixture.waitForStart()
        let afterCurrentDisplay = await fixture.starts
        XCTAssertEqual(afterCurrentDisplay, 1)
        store.cancel(); await fixture.complete(.cancelled)
        try await wait { !store.isBusy }
    }

    @MainActor
    func testReviewArmsAfterLateWindowAttachmentWithoutAnotherModelUpdate() async throws {
        _ = NSApplication.shared
        let fixture = OperationTerminalAttachmentFixture()
        let store = MoleUpgradeTerminalStore(executor: fixture)
        store.prepare(source: .appleSiliconHomebrew, currentVersion: "1.50.0", recommendedVersion: "1.58.0")
        try await wait { store.isReady }
        let planID = try XCTUnwrap(store.plan?.id)
        let coordinator = OperationTerminalRepresentable.Coordinator(store: store)
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        terminal.terminalDelegate = coordinator
        coordinator.install(terminal)
        coordinator.update(terminal)
        XCTAssertNil(terminal.window)
        // Let the original one-shot presentation/focus callback miss attachment.
        try await Task.sleep(for: .milliseconds(30))
        let beforeAttachment = await fixture.starts
        XCTAssertEqual(beforeAttachment, 0)
        XCTAssertTrue(store.isReady)
        XCTAssertFalse(coordinator.hasDisplayedReview(planID: planID, in: terminal))

        let window = OperationTerminalCaptureWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = terminal
        defer { coordinator.removeMonitor(); window.orderOut(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        NSApp.updateWindows() // real AppKit key/visibility/update notifications, no coordinator.update()
        func enterEvent() throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        }
        if !coordinator.hasDisplayedReview(planID: planID, in: terminal) {
            // Early input must remain inert; it must not force-display and launch.
            XCTAssertTrue(coordinator.handleKeyEvent(try enterEvent(), terminal: terminal))
            XCTAssertTrue(store.isReady)
            let prematureStarts = await fixture.starts
            XCTAssertEqual(prematureStarts, 0)
        }
        // Window visibility/layout notifications can finish on a later AppKit
        // turn. Observe their receipt without drawing, updating, or sending input.
        try await wait { coordinator.hasDisplayedReview(planID: planID, in: terminal) }
        guard coordinator.hasDisplayedReview(planID: planID, in: terminal) else {
            store.cancel(); await fixture.complete(.cancelled)
            return // the bounded wait already recorded the missing presentation
        }
        XCTAssertEqual(store.plan?.id, planID)
        XCTAssertTrue(store.isReady)
        let beforeFreshEnter = await fixture.starts
        XCTAssertEqual(beforeFreshEnter, 0)
        XCTAssertTrue(coordinator.handleKeyEvent(try enterEvent(), terminal: terminal))
        XCTAssertEqual(store.phase, .running) // plan consumption is synchronous
        for _ in 0..<600 {
            if await fixture.isWaitingForCompletion { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waitingForCompletion = await fixture.isWaitingForCompletion
        XCTAssertTrue(waitingForCompletion, "The accepted Return did not start the synthetic executor")
        let afterPresentation = await fixture.starts
        XCTAssertEqual(afterPresentation, 1)
        store.cancel(); await fixture.complete(.cancelled)
        try await wait { !store.isBusy }
    }

    @MainActor
    func testDeferredFocusDoesNotOutliveTheReviewOrUserFocus() async throws {
        _ = NSApplication.shared
        for interruption in ["cancel", "replace", "focus", "dismiss", "hide"] {
            let fixture = OperationTerminalFixture()
            let store = MoleUpgradeTerminalStore(executor: fixture)
            store.prepare(source: .appleSiliconHomebrew, currentVersion: "1.50.0", recommendedVersion: "1.58.0")
            try await wait { store.isReady }
            let coordinator = OperationTerminalRepresentable.Coordinator(store: store)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
            let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 380))
            let firstEditor = NSTextView(frame: NSRect(x: 0, y: 390, width: 200, height: 30))
            let secondEditor = NSTextView(frame: NSRect(x: 220, y: 390, width: 200, height: 30))
            content.addSubview(terminal); content.addSubview(firstEditor); content.addSubview(secondEditor)
            let window = OperationTerminalCaptureWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = content
            terminal.terminalDelegate = coordinator; coordinator.install(terminal)
            window.makeKeyAndOrderFront(nil)
            XCTAssertTrue(window.makeFirstResponder(firstEditor))
            coordinator.update(terminal) // schedules first-responder work for the next turn
            switch interruption {
            case "cancel": store.cancel()
            case "replace":
                store.cancel()
                store.prepare(source: .intelHomebrew, currentVersion: "1.50.0", recommendedVersion: "1.58.0")
            case "focus": XCTAssertTrue(window.makeFirstResponder(secondEditor))
            case "dismiss": coordinator.removeMonitor()
            case "hide": window.orderOut(nil)
            default: XCTFail("Unknown focus interruption")
            }
            try await Task.sleep(for: .milliseconds(30))
            let expected: NSResponder = interruption == "focus" ? secondEditor : firstEditor
            XCTAssertTrue(window.firstResponder === expected, "Stale callback stole focus after \(interruption)")
            let starts = await fixture.starts
            XCTAssertEqual(starts, 0)
            store.cancel(); coordinator.removeMonitor()
            window.orderOut(nil); window.contentView = nil; window.close()
        }
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Synthetic terminal state did not settle")
    }
    @MainActor private func findTerminal(in view: NSView) -> TerminalView? {
        if let view = view as? TerminalView { return view }
        for child in view.subviews { if let result = findTerminal(in: child) { return result } }
        return nil
    }
}

@MainActor private final class OperationTerminalCaptureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Explicit start/completion handshake for the late-attachment scheduling test.
/// A completion requested before run() is remembered, never silently discarded.
private actor OperationTerminalAttachmentFixture: MoleUpgradeExecuting {
    private let planFactory = OperationTerminalFixture()
    private(set) var starts = 0
    private var completion: CheckedContinuation<OperationTerminalOutcome, Never>?
    private var result: OperationTerminalOutcome?
    var isWaitingForCompletion: Bool { completion != nil }

    func prepare(source: MoleUpgradeSource, currentVersion: String?, recommendedVersion: String) async -> MoleUpgradePlan {
        await planFactory.prepare(source: source, currentVersion: currentVersion, recommendedVersion: recommendedVersion)
    }
    func run(_ plan: MoleUpgradePlan, input: OperationTerminalInput,
             onOutput: @escaping @Sendable (Data) async -> Void) async -> OperationTerminalOutcome {
        starts += 1
        if let result { return result }
        return await withCheckedContinuation { completion = $0 }
    }
    func complete(_ result: OperationTerminalOutcome) {
        self.result = result
        completion?.resume(returning: result); completion = nil
    }
}
