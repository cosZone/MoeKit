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
                    workingDirectory: "/Synthetic/project with spaces", listeningPorts: [ListeningPort(port: 3000, address: "127.0.0.1", transport: "TCP")],
                    credentials: ProcessCredentials(realUID: 501, effectiveUID: 501, savedUID: 501,
                        realGID: 20, effectiveGID: 20, savedGID: 20, hasSetIDHistory: false))
                let snapshot = ProcessSnapshot(records: [row], currentUID: 501, observerPID: 900, currentGID: 20)
                let plan = ProcessStopPlanner.makePlan(snapshot: snapshot, selection: [row.identity], projects: [])
                let fake = RenderStopSystem(row: row)
                let termination = ProcessTerminationStore(executor: ProcessTerminationExecutor(system: fake))
                termination.prepare([row], mode: .graceful)
                try await settle(termination)
                if force {
                    let id = try XCTUnwrap(termination.review?.id)
                    termination.acknowledge(reviewID: id, value: true)
                    termination.confirm(reviewID: id)
                    try await settle(termination)
                    termination.prepare(termination.forceCandidates, mode: .force)
                    try await settle(termination)
                }
                XCTAssertNotNil(termination.review)
                _ = NSApplication.shared
                let size = NSSize(width: 740, height: 780)
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let capture = ProcessStopRenderCapture()
                XCTAssertNil(EnvironmentValues().installerCaptureCollector)
                let view = ProcessStopPlanView(plan: plan, termination: termination)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale.current)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .installerCaptureViewport()
                    .environment(\.installerCaptureCollector, { capture.regions = $0 })
                let hosting = NSHostingView(rootView: view)
                hosting.sizingOptions = []; hosting.frame = NSRect(origin: .zero, size: size); hosting.appearance = appearance
                let window = ProcessStopCaptureWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = hosting
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                window.orderFront(nil)
                for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
                XCTAssertEqual(hosting.bounds.size, size)
                let required = ["process.mode", "process.targets", "process.identity.1234", "process.acknowledgement", "process.confirm", "process.cancel"]
                for id in required {
                    let region = try XCTUnwrap(capture.regions.first { $0.id == id })
                    XCTAssertGreaterThan(region.bounds.width, 0)
                    XCTAssertGreaterThan(region.bounds.height, 0)
                    XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1).contains(region.bounds), "Missing visible control: \(id): \(region.bounds)")
                }
                XCTAssertTrue(capture.regions.first { $0.id == "process.identity.1234" }?.text.contains("\\u{A}") == true)
                XCTAssertNil(termination.acknowledgedReviewID)
                hosting.displayIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = "process-stop-\(force ? "force" : "graceful")-\(language)-\(dark ? "dark" : "light")-740x780"
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name + ".png"; attachment.lifetime = .keepAlways; add(attachment)
                XCTAssertGreaterThan(png.count, 1000)
                let signals = await fake.signals
                XCTAssertEqual(signals, force ? 1 : 0) // synthetic TERM establishes the force-review state
                let scope = XCTAttachment(string: """
                Bundle language: \(language)
                Process locale: \(Locale.current.identifier)
                Projects title: \(WorkspaceSection.projects.title)
                Partial-result title: \(TaskStatus.partial.title)
                Content size: 740 × 780 points
                Native signals: 0
                Visible required controls: 6
                Confirmation initially acknowledged: false
                Evidence source: public SwiftUI bounds anchors on displayed views
                Synthetic confirmation only. Mock signals: \(signals). No keyboard/VoiceOver acceptance claimed.
                \(capture.regions.map { "\($0.id): \($0.bounds)" }.joined(separator: "\n"))
                """)
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
        ProcessSnapshot(records: [row], currentUID: 501, observerPID: 900, currentGID: 20)
    }
    func signal(_ record: ProcessInventoryRecord, mode: ProcessStopMode, authority: ProcessSignalAuthority) async throws { try authority.submit { signals += 1 } }
    func presence(of identity: ProcessIdentity) async -> ProcessPresence { .running }
}


@MainActor private final class ProcessStopCaptureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private final class ProcessStopRenderCapture {
    var regions: [InstallerCaptureRegion] = []
}
