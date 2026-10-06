import AppKit
import SwiftUI
import Observation
import XCTest
@testable import MoeKit

/// Owned synthetic views only: no real Trash executor or filesystem mutation.
final class TrashViewTests: XCTestCase {
    @MainActor
    func testTrashConfirmationsRender() async throws {
        let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
        XCTAssertEqual(String(localized: "Trash management"), language == "zh-Hans" ? "废纸篓管理" : "Trash management")
        for clear in [false, true] {
            for dark in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-Trash-Render-\(UUID())")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let workspace = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory))
                let fixture = TrashStoreFixture(), store = TrashStore(executor: fixture)
                store.updateContext(.init(isDemoEnabled: false, modeGeneration: workspace.toolPreparation.modeGeneration))
                store.inspect(); await settle(store)
                store.select(paths: Set(store.items.map(\.id)))
                store.prepare(action: clear ? .clearSnapshot : .selectedItems); await settle(store)
                let plan = try XCTUnwrap(store.plan)
                XCTAssertFalse(store.canConfirm(planID: plan.id))
                _ = NSApplication.shared
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let capture = TrashRenderCapture()
                let size = NSSize(width: 960, height: 1800)
                let view = TrashWorkspaceView(store: store).environment(workspace)
                    .environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, Locale.current)
                    .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                    .installerCaptureViewport().environment(\.installerCaptureCollector, { capture.regions = $0 })
                let hosting = NSHostingView(rootView: view)
                hosting.sizingOptions = []; hosting.frame = .init(origin: .zero, size: size); hosting.appearance = appearance
                let window = TrashCaptureWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = hosting; window.appearance = appearance
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                window.orderFront(nil)
                for _ in 0..<10 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)); window.setContentSize(size) }
                let required = ["trash.heading", "trash.scan", "trash.root", "trash.review.heading", "trash.review.effects", "trash.review.records",
                                "trash.review.workloads", "trash.review.irreversible", "trash.review.cancel", "trash.review.confirm"]
                let viewport = CGRect(origin: .zero, size: size)
                for id in required {
                    let matches = capture.regions.filter { $0.id == id }
                    XCTAssertEqual(matches.count, 1, "Missing/duplicate displayed anchor \(id)")
                    let region = try XCTUnwrap(matches.first)
                    XCTAssertFalse(region.bounds.isEmpty)
                    XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(region.bounds), "Clipped \(id): \(region.bounds)")
                    XCTAssertFalse(region.text.isEmpty)
                }
                let calls = await fixture.removeCount
                XCTAssertEqual(calls, 0)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "trash-\(clear ? "clear" : "selected")-\(language)-\(dark ? "dark" : "light").png"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
    @MainActor
    func testNavigationKeepsInFlightResultsAndErrorsReachable() async throws {
        for fail in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-Trash-Navigation-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let fixture = TrashStoreFixture(holdMutation: true, failMutation: fail)
            let operation = TrashStore(executor: fixture)
            let workspace = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory), trash: operation)
            let navigation = TrashNavigationState(), capture = TrashRenderCapture()
            let hosting = NSHostingView(rootView: TrashNavigationHarness(navigation: navigation).environment(workspace)
                .frame(width: 960, height: 1800).installerCaptureViewport()
                .environment(\.installerCaptureCollector, { capture.regions = $0 }))
            hosting.sizingOptions = []; hosting.frame = .init(x: 0, y: 0, width: 960, height: 1800)
            let window = TrashCaptureWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await layout(hosting)
            workspace.trash.inspect(); await settle(operation)
            operation.select(paths: Set(operation.items.map(\.id))); operation.prepare(action: .selectedItems); await settle(operation)
            let plan = try XCTUnwrap(operation.plan)
            operation.attestIrreversible(true, planID: plan.id); operation.attestWorkloadsStopped(true, planID: plan.id)
            operation.confirm(planID: plan.id); await fixture.waitUntilHeld()
            try await layout(hosting)
            XCTAssertTrue(operation.isBusy); XCTAssertFalse(UpdateInstallationSafety.shared.canTerminate)
            navigation.showTrash = false; try await layout(hosting)
            XCTAssertTrue(operation.isBusy && operation.isCancelling)
            XCTAssertFalse(capture.regions.contains { $0.id == "trash.heading" })
            navigation.showTrash = true; try await layout(hosting)
            XCTAssertTrue(workspace.trash === operation)
            XCTAssertTrue(capture.regions.contains { $0.id == "trash.progress.state" })
            XCTAssertNotNil(operation.progress); XCTAssertFalse(UpdateInstallationSafety.shared.canTerminate)
            await fixture.release(); await settle(operation); try await layout(hosting)
            XCTAssertFalse(operation.blocksAppUpdate)
            if fail {
                XCTAssertNotNil(workspace.trash.lastMutationError)
                XCTAssertTrue(capture.regions.contains { $0.id == "trash.mutation.error" })
            } else {
                XCTAssertEqual(workspace.trash.lastOutcome?.items.map(\.status), [.deleted, .notAttempted])
                XCTAssertTrue(capture.regions.contains { $0.id == "trash.outcome.heading" })
            }
            // Tear down the complete hosting tree, then construct another one.
            // The workspace, not an old view identity, owns the actual result.
            window.contentView = nil
            let replacement = NSHostingView(rootView: TrashWorkspaceView().environment(workspace).frame(width: 960, height: 1800))
            window.contentView = replacement; try await layout(replacement)
            XCTAssertTrue(workspace.trash === operation)
            XCTAssertTrue(fail ? workspace.trash.lastMutationError != nil : workspace.trash.lastOutcome != nil)
        }
    }
    @MainActor private func layout(_ view: NSView) async throws {
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
    }
    @MainActor private func settle(_ store: TrashStore) async {
        let deadline = Date().addingTimeInterval(5)
        while store.isBusy && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isBusy)
    }
}
@MainActor private final class TrashCaptureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private final class TrashRenderCapture { var regions: [InstallerCaptureRegion] = [] }

@MainActor @Observable private final class TrashNavigationState { var showTrash = true }
@MainActor private struct TrashNavigationHarness: View {
    let navigation: TrashNavigationState
    var body: some View {
        if navigation.showTrash { TrashWorkspaceView() }
        else { Text("Synthetic alternate workspace") }
    }
}
