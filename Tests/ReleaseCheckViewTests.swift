import AppKit
import SwiftUI
import XCTest
@testable import MoeKit

final class ReleaseCheckViewTests: XCTestCase {
    @MainActor
    func testUpdatePanelAndHiddenIconsRender() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-update-render-\(UUID().uuidString)")
        // An absent, unique catalog path is sufficient; this read-only fixture
        // never creates a catalog or recursively removes a directory.
        for scenario in ["available", "current", "development", "failure", "cancelled", "hidden-icons"] {
            let checker = FixtureReleaseChecker(fails: scenario == "failure")
            let version = scenario == "development" ? nil : ReleaseVersion(scenario == "current" ? "0.1.0-preview.10" : "0.1.0-preview.7")
            let updates = ReleaseCheckStore(checker: checker, installedVersion: version)
            if scenario != "hidden-icons" {
                updates.check()
                if scenario == "cancelled" { updates.cancel() }
                let deadline = ContinuousClock.now + .seconds(5)
                while updates.isChecking && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertFalse(updates.isChecking)
            }
            let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
            XCTAssertTrue(["en", "zh-Hans"].contains(language))
            XCTAssertEqual(String(localized: "Check for updates…"), language == "zh-Hans" ? "检查更新…" : "Check for updates…")
            let size = scenario == "hidden-icons" ? NSSize(width: 520, height: 600) : NSSize(width: 540, height: 520)
            for dark in [false, true] {
                _ = NSApplication.shared
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let name = "updates-\(scenario)-\(language)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
                let content: AnyView
                if scenario == "hidden-icons" {
                    let visibility = AppVisibilityPreferences()
                    visibility.showDockIcon = false; visibility.showMenuBarIcon = false
                    content = AnyView(SettingsView()
                        .environment(visibility)
                        .environment(WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory))))
                } else { content = AnyView(ReleaseCheckView(updates: updates)) }
                let capture = UpdateRenderCapture()
                let hosting = NSHostingView(rootView: content
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale.current)
                    .frame(width: size.width, height: size.height)
                    .installerCaptureViewport()
                    .environment(\.installerCaptureCollector, { capture.regions = $0 }))
                hosting.sizingOptions = []
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.appearance = appearance
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                window.contentView = hosting
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                // Anchor onChange delivery follows visibility; this is an owned
                // fixture window, never a screenshot of the runner desktop.
                window.orderFront(nil)
                for _ in 0..<5 {
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(50))
                    window.setContentSize(size)
                }
                XCTAssertEqual(hosting.bounds.size, size)
                var required = scenario == "hidden-icons" ? ["icons.dock", "icons.menu", "icons.recovery"]
                    : ["updates.channel", "updates.result", "updates.check", "updates.installation", "updates.releases", "updates.privacy"]
                if ["available", "development"].contains(scenario) { required.append("updates.download") }
                let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)
                let visible = required.filter { id in
                    capture.regions.contains { $0.id == id && $0.bounds.width > 0 && $0.bounds.height > 0 && viewport.contains($0.bounds) }
                }
                let geometry = capture.regions.map { "\($0.id): \($0.bounds)" }.joined(separator: "\n")
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1000)
                let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                image.name = name + ".png"; image.lifetime = .keepAlways; add(image)
                let scope = XCTAttachment(string: """
                Content size: \(Int(size.width)) × \(Int(size.height)) points
                Process locale: \(Locale.current.identifier)
                Bundle language: \(language)
                Projects title: \(WorkspaceSection.projects.title)
                Partial-result title: \(TaskStatus.partial.title)
                Update action title: \(String(localized: "Check for updates…"))
                Network requests: 0
                Visible required controls: \(visible.count)
                Evidence source: public SwiftUI bounds anchors on displayed views
                Scope: owned release/settings views with isolated preferences and synthetic responses.
                Scenario: \(scenario)
                Required controls: \(required.joined(separator: ", "))
                Collected geometry:
                \(geometry)
                No live update, installation, screen capture or accessibility acceptance claimed.
                """)
                scope.name = name + "-scope.txt"; scope.lifetime = .keepAlways; add(scope)
                // Keep the diagnostic pixels and all collected regions even if
                // layout fails, while still failing the same required controls.
                XCTAssertEqual(Set(visible), Set(required), "Missing/clipped controls in \(scenario): \(Set(required).subtracting(visible)); collected: \(geometry)")
            }
        }
    }
}

private struct FixtureReleaseChecker: ReleaseChecking {
    let fails: Bool
    func releases() async throws -> [PublishedRelease] {
        if fails { throw ReleaseCheckError.rateLimited }
        return [PublishedRelease(version: ReleaseVersion("0.1.0-preview.10")!)]
    }
}

@MainActor private final class UpdateRenderCapture { var regions: [InstallerCaptureRegion] = [] }
