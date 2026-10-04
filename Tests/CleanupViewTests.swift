import AppKit
import SwiftUI
import XCTest
@testable import MoeKit

/// Synthetic owned-view rendering only. The injected actor has no filesystem
/// executor; no cache scan, signal, native Trash or permanent deletion can occur.
final class CleanupViewTests: XCTestCase {
    @MainActor
    func testCleanupConfirmationRenders() async throws {
        let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
        XCTAssertTrue(["en", "zh-Hans"].contains(language))
        XCTAssertEqual(String(localized: "Native cache cleanup"), language == "zh-Hans" ? "原生缓存清理" : "Native cache cleanup")
        for scenario in ["first-use", "trash-review", "permanent-review"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-cache-render-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let workspace = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory))
            let store = CleanupStore(executor: CleanupStoreFixture())
            store.updateContext(.init(isDemoEnabled: false, modeGeneration: workspace.toolPreparation.modeGeneration,
                                      protectedPaths: [], catalogIsKnown: true))
            if scenario == "trash-review" {
                let root = URL(fileURLWithPath: "/Synthetic/Caches", isDirectory: true)
                store.selectRoot(root, ticket: try XCTUnwrap(store.selectionTicket()))
                store.inspect(); await settle(store)
                store.select(paths: Set(store.candidates.filter(\.isEligible).map(\.id)))
                store.prepare(); await settle(store)
                let plan = try XCTUnwrap(store.plan)
                XCTAssertFalse(store.canConfirm(planID: plan.id))
            } else if scenario == "permanent-review" {
                store.loadRecovery(); await settle(store)
                store.prepareRecovery(receiptID: try XCTUnwrap(store.receipts.first?.id), action: .deletePermanently)
                await settle(store)
                let plan = try XCTUnwrap(store.recoveryPlan)
                XCTAssertFalse(store.canConfirmRecovery(planID: plan.id))
            }
            for dark in [false, true] {
                _ = NSApplication.shared
                let size = NSSize(width: 760, height: 1800)
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let view = CleanupWorkspaceView(store: store).environment(workspace)
                    .environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, Locale.current)
                    .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: view)
                hosting.sizingOptions = []; hosting.frame = NSRect(origin: .zero, size: size); hosting.appearance = appearance
                for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                hosting.displayIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 2000)
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "cache-\(scenario)-\(language)-\(dark ? "dark" : "light").png"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
    @MainActor
    private func settle(_ store: CleanupStore) async {
        for _ in 0..<1000 {
            if !store.isBusy { return }
            await Task.yield()
        }
        XCTFail("Synthetic cleanup store did not settle")
    }
}
