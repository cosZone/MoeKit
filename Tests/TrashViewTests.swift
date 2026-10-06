import AppKit
import SwiftUI
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
