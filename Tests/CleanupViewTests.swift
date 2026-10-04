import AppKit
import SwiftUI
import XCTest
@testable import MoeKit

/// Displayed SwiftUI geometry and owned pixels, not keyboard/VoiceOver claims.
/// The injected actor has no filesystem executor. Fixture catalogs are retained.
final class CleanupViewTests: XCTestCase {
    @MainActor
    func testCleanupConfirmationRenders() async throws {
        let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
        XCTAssertTrue(["en", "zh-Hans"].contains(language))
        XCTAssertEqual(String(localized: "Native cache cleanup"), language == "zh-Hans" ? "原生缓存清理" : "Native cache cleanup")
        for scenario in ["first-use", "trash-review", "restore-review", "permanent-review", "uncertain-recovery"] {
            for dark in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-cache-render-\(UUID())")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let workspace = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory))
                let fixture = CleanupStoreFixture(incompleteRecovery: scenario == "uncertain-recovery", longInventory: true)
                let store = CleanupStore(executor: fixture)
                store.updateContext(.init(isDemoEnabled: false, modeGeneration: workspace.toolPreparation.modeGeneration,
                                          protectedPaths: [], catalogIsKnown: true))
                var required = ["cleanup.heading"]
                var exactPaths: [String: String] = [:]
                var controlPrefix: String?
                if scenario == "trash-review" {
                    let root = URL(fileURLWithPath: "/Synthetic/Caches", isDirectory: true)
                    store.selectRoot(root, ticket: try XCTUnwrap(store.selectionTicket()))
                    store.inspect(); await settle(store)
                    store.select(paths: Set(store.candidates.filter(\.isEligible).map(\.id)))
                    store.prepare(); await settle(store)
                    let plan = try XCTUnwrap(store.plan)
                    XCTAssertFalse(store.canConfirm(planID: plan.id))
                    controlPrefix = "cleanup.trash"
                    required += ["cleanup.trash.heading", "cleanup.trash.effects", "cleanup.trash.use-warning", "cleanup.trash.workload-attestation", "cleanup.trash.content-attestation", "cleanup.trash.recovery-path", "cleanup.trash.confirm", "cleanup.trash.cancel"]
                    for (index, target) in plan.targets.enumerated() {
                        let id = "cleanup.trash.target.\(index).root"
                        required.append(id); exactPaths[id] = InstallerPathDisplay.quoted(target.originalURL.path)
                    }
                    exactPaths["cleanup.trash.recovery-path"] = InstallerPathDisplay.quoted(plan.recoveryRoot.path)
                } else if scenario != "first-use" {
                    store.loadRecovery(); await settle(store)
                    if scenario == "uncertain-recovery" {
                        required += ["cleanup.unknown.warning", "cleanup.unknown.effects"]
                        XCTAssertTrue(store.receipts.isEmpty)
                    } else {
                        store.prepareRecovery(receiptID: try XCTUnwrap(store.receipts.first?.id), action: scenario == "restore-review" ? .restore : .deletePermanently)
                        await settle(store)
                        let plan = try XCTUnwrap(store.recoveryPlan)
                        controlPrefix = "cleanup.recovery"
                        required += ["cleanup.recovery.original-path", "cleanup.recovery.target.root", "cleanup.recovery.records", "cleanup.recovery.effects", "cleanup.recovery.confirm", "cleanup.recovery.cancel"]
                        exactPaths["cleanup.recovery.original-path"] = InstallerPathDisplay.quoted(plan.receipt.target.originalURL.path)
                        exactPaths["cleanup.recovery.target.root"] = InstallerPathDisplay.quoted(plan.sourceURL.path)
                        exactPaths["cleanup.recovery.records"] = InstallerPathDisplay.quoted(plan.receipt.operationURL.path)
                        if scenario == "permanent-review" {
                            required.append("cleanup.recovery.attestation")
                            XCTAssertFalse(store.canConfirmRecovery(planID: plan.id))
                        }
                    }
                }
                _ = NSApplication.shared
                XCTAssertNil(EnvironmentValues().installerCaptureCollector)
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let capture = CacheRenderCapture()
                let makeView = { (size: NSSize) in
                    CleanupWorkspaceView(store: store).environment(workspace)
                        .environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, Locale.current)
                        .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor))
                        .installerCaptureViewport().environment(\.installerCaptureCollector, { capture.record($0) })
                }
                let size = NSSize(width: 760, height: 2200)
                let hosting = NSHostingView(rootView: makeView(size))
                hosting.sizingOptions = []; hosting.frame = NSRect(origin: .zero, size: size); hosting.appearance = appearance
                let window = CacheCaptureWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = hosting; window.appearance = appearance
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                window.orderFront(nil)
                for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)); window.setContentSize(size) }
                resetScrollOrigins(hosting)
                try await finishLayout(hosting)
                let prefix = "cache-\(scenario)-\(language)-\(dark ? "dark" : "light")"
                try await captureFrame(name: prefix, hosting: hosting, appearance: appearance, capture: capture,
                    required: required, exactPaths: exactPaths, fixture: fixture, compact: false, language: language)
                if let controlPrefix {
                    let compact = NSSize(width: 760, height: 560)
                    capture.regions = []; hosting.rootView = makeView(compact); window.setContentSize(compact)
                    for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
                    resetScrollOrigins(hosting); try await finishLayout(hosting)
                    let controls = [controlPrefix + ".confirm", controlPrefix + ".cancel"]
                    try await scrollTo(controls, hosting: hosting, capture: capture)
                    try await captureFrame(name: prefix + "-compact", hosting: hosting, appearance: appearance, capture: capture,
                        required: controls, exactPaths: [:], fixture: fixture, compact: true, language: language)
                }
            }
        }
    }
    @MainActor private func captureFrame(name: String, hosting: NSView, appearance: NSAppearance, capture: CacheRenderCapture,
                                         required: [String], exactPaths: [String: String], fixture: CleanupStoreFixture,
                                         compact: Bool, language: String) async throws {
        try await finishLayout(hosting)
        let viewport = CGRect(origin: .zero, size: hosting.bounds.size)
        var frames: [[String: Any]] = []
        for id in required {
            let matches = capture.regions.filter { $0.id == id }
            XCTAssertEqual(matches.count, 1, "Missing/duplicate actual displayed anchor \(id)")
            let region = try XCTUnwrap(matches.first)
            XCTAssertFalse(region.bounds.isEmpty)
            XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(region.bounds), "Clipped \(id): \(region.bounds) / \(viewport)")
            XCTAssertFalse(region.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let exact = exactPaths[id] { XCTAssertEqual(region.text, exact) }
            frames.append(["id": id, "text": region.text, "bounds": [region.bounds.minX, region.bounds.minY, region.bounds.width, region.bounds.height]])
        }
        let moves = await fixture.moveCount
        let applications = await fixture.applyCount
        let mutations = moves + applications
        XCTAssertEqual(mutations, 0)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        image.name = name + ".png"; image.lifetime = .keepAlways; add(image)
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "name": name, "language": language,
            "width": Int(viewport.width), "height": Int(viewport.height), "compact": compact,
            "mutationCalls": mutations, "requiredIDs": required, "frames": frames,
            "scope": "owned synthetic cleanup views; public SwiftUI bounds; no keyboard or VoiceOver acceptance"], options: [.sortedKeys])
        let scope = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        scope.name = name + "-scope.json"; scope.lifetime = .keepAlways; add(scope)
    }
    @MainActor private func finishLayout(_ hosting: NSView) async throws {
        for _ in 0..<5 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        hosting.displayIfNeeded()
    }
    @MainActor private func scrollTo(_ ids: [String], hosting: NSView, capture: CacheRenderCapture) async throws {
        func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews) }
        let scroll = try XCTUnwrap(scrollViews(hosting).first), document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        let old = scroll.contentView.bounds.origin
        for _ in 0..<20 {
            let values = ids.compactMap { id in capture.regions.first { $0.id == id }?.bounds }
            if values.count == ids.count, let first = values.first {
                let rect = values.dropFirst().reduce(first) { $0.union($1) }
                let hostRect = hosting.isFlipped ? rect : CGRect(x: rect.minX, y: hosting.bounds.height - rect.maxY, width: rect.width, height: rect.height)
                let target = document.convert(hostRect, from: hosting)
                let y = min(max(target.midY - scroll.contentView.bounds.height / 2, document.bounds.minY), max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height))
                let revision = capture.revision
                document.scroll(NSPoint(x: document.bounds.minX, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                try await finishLayout(hosting)
                let viewport = CGRect(origin: .zero, size: hosting.bounds.size).insetBy(dx: -0.5, dy: -0.5)
                let current = ids.compactMap { id in capture.regions.first { $0.id == id }?.bounds }
                if capture.revision > revision, current.count == ids.count, current.allSatisfy({ !$0.isEmpty && viewport.contains($0) }) {
                    XCTAssertNotEqual(old, scroll.contentView.bounds.origin); return
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Confirmed/cancel controls did not enter compact viewport with fresh layout")
        throw NSError(domain: "CacheRender", code: 1)
    }
    @MainActor private func resetScrollOrigins(_ view: NSView) {
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            let y = document.isFlipped ? document.frame.minY : max(document.frame.minY, document.frame.maxY - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: document.frame.minX, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        for child in view.subviews { resetScrollOrigins(child) }
    }
    @MainActor private func settle(_ store: CleanupStore) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !store.isBusy { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Synthetic cleanup store did not settle")
    }
}
@MainActor private final class CacheCaptureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private final class CacheRenderCapture {
    var regions: [InstallerCaptureRegion] = []
    var revision = 0
    func record(_ value: [InstallerCaptureRegion]) { regions = value; revision += 1 }
}
