import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import MoeKit

final class ProcessStopViewTests: XCTestCase {
    @MainActor
    func testStopConfirmationRenders() async throws {
        let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
        if language == "zh-Hans" {
            XCTAssertEqual(String(localized: "Confirm graceful stop (SIGTERM)"), "确认正常停止（SIGTERM）")
            XCTAssertEqual(String(localized: "Force stop these processes"), "强制停止这些进程")
            XCTAssertEqual(String(localized: "I checked each listed target and accept these consequences"), "我已核对每个列出目标并接受上述后果")
        }
        for force in [false, true] {
            for dark in [false, true] {
                let row = ProcessInventoryRecord(identity: ProcessIdentity(pid: 1234, startSeconds: 1_790_000_000,
                    startMicroseconds: 123_456, uid: 501,
                    executablePath: "/Synthetic/project with spaces/line\nbreak/方向\u{202E}名/worker", executionVersion: 99),
                    name: "Synthetic worker", parentPID: 123, processGroupID: 123,
                    workingDirectory: "/Synthetic/project with spaces", listeningPorts: [ListeningPort(port: 3000, address: "127.0.0.1", transport: "TCP")])
                let snapshot = ProcessSnapshot(records: [row], currentUID: 501, observerPID: 900)
                let plan = ProcessStopPlanner.makePlan(snapshot: snapshot, selection: [row.identity], projects: [])
                let fake = RenderStopSystem(row: row)
                let termination = ProcessTerminationStore(executor: ProcessTerminationExecutor(system: fake))
                termination.prepare([row], mode: .graceful)
                try await settle(termination)
                if force {
                    termination.confirm(reviewID: try XCTUnwrap(termination.review?.id))
                    try await settle(termination)
                    termination.prepare(termination.forceCandidates, mode: .force)
                    try await settle(termination)
                }
                XCTAssertNotNil(termination.review)
                _ = NSApplication.shared
                let size = NSSize(width: 740, height: 780)
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let view = ProcessStopPlanView(plan: plan, termination: termination)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale.current)
                    .frame(width: size.width, height: size.height)
                let hosting = NSHostingView(rootView: view)
                hosting.sizingOptions = []; hosting.frame = NSRect(origin: .zero, size: size); hosting.appearance = appearance
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = hosting
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                window.orderFront(nil)
                for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
                hosting.displayIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = "process-stop-\(force ? "force" : "graceful")-\(language)-\(dark ? "dark" : "light")"
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name + ".png"; attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertGreaterThan(png.count, 1000)
                let signals = await fake.signals
                XCTAssertEqual(signals, force ? 1 : 0) // synthetic TERM establishes the force-review state
                let scope = XCTAttachment(string: "Synthetic confirmation only; no native process access or signals. Bundle language: \(language). Mock signals: \(signals). No keyboard/VoiceOver acceptance claimed.")
                scope.name = name + "-scope.txt"; scope.lifetime = .keepAlways; add(scope)
            }
        }
    }

    @MainActor private func settle(_ store: ProcessTerminationStore) async throws {
        for _ in 0..<600 {
            if !store.isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic confirmation did not settle")
    }
}

private actor RenderStopSystem: ProcessTerminationSystem {
    let row: ProcessInventoryRecord
    var signals = 0
    init(row: ProcessInventoryRecord) { self.row = row }
    func inspect(_ identities: [ProcessIdentity]) async throws -> ProcessSnapshot {
        ProcessSnapshot(records: [row], currentUID: 501, observerPID: 900)
    }
    func signal(_ record: ProcessInventoryRecord, mode: ProcessStopMode) async throws { signals += 1 }
    func presence(of identity: ProcessIdentity) async -> ProcessPresence { .running }
}
