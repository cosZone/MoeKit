import AppKit
import SwiftUI
import XCTest
@testable import MoeKit

final class AutomaticUpdateSettingsTests: XCTestCase {
    @MainActor
    func testAutomaticUpdateSettingsRender() async throws {
        let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
        XCTAssertTrue(["en", "zh-Hans"].contains(language))
        XCTAssertEqual(String(localized: "Automatically check for updates"),
                       language == "zh-Hans" ? "自动检查更新" : "Automatically check for updates")
        for scenario in ["enabled", "disabled", "unconfigured", "failed"] {
            let driver = SettingsUpdateFixture()
            driver.failStart = scenario == "failed"
            driver.snapshot.checksAutomatically = scenario == "enabled"
            driver.snapshot.downloadsAutomatically = scenario == "enabled"
            let config = scenario == "unconfigured" ? nil : SparkleUpdateConfiguration(info: SparkleUpdateTests.info)
            let store = SparkleUpdateStore(configuration: config, isolated: false, defaults: nil, makeDriver: { _, _ in driver })
            store.start()
            for dark in [false, true] {
                let size = NSSize(width: 520, height: 520)
                let name = "sparkle-settings-\(scenario)-\(language)-\(dark ? "dark" : "light")-520x520"
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let capture = AutomaticUpdateRenderCapture()
                let content = Form { AutomaticUpdateSettings(updates: store, openManualReleases: {}) }
                    .formStyle(.grouped)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale.current)
                    .frame(width: size.width, height: size.height)
                    .installerCaptureViewport()
                    .environment(\.installerCaptureCollector, { capture.regions = $0 })
                let hosting = NSHostingView(rootView: content)
                hosting.sizingOptions = []
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.appearance = appearance
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = hosting
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                window.orderFront(nil)
                for _ in 0..<5 {
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(50))
                    window.setContentSize(size)
                }
                let required = store.isStarted
                    ? ["sparkle.check", "sparkle.checks", "sparkle.downloads", "sparkle.previews", "sparkle.behavior", "sparkle.privacy"]
                    : ["sparkle.unavailable", "sparkle.releases", "sparkle.privacy"]
                let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)
                let visible = required.filter { id in capture.regions.contains {
                    $0.id == id && $0.bounds.width > 0 && $0.bounds.height > 0 && viewport.contains($0.bounds)
                } }
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let image = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                image.name = name + ".png"; image.lifetime = .keepAlways; add(image)
                let scope = XCTAttachment(string: """
                Content size: 520 × 520 points
                Process locale: \(Locale.current.identifier)
                Bundle language: \(language)
                Automatic check title: \(String(localized: "Automatically check for updates"))
                Network requests: 0
                Installer launches: 0
                Visible required controls: \(visible.count)
                Scenario: \(scenario)
                Scope: owned settings view, synthetic updater driver, no production signing key.
                Evidence source: public SwiftUI bounds anchors on displayed views
                \(capture.regions.map { "\($0.id): \($0.bounds)" }.joined(separator: "\n"))
                """)
                scope.name = name + "-scope.txt"; scope.lifetime = .keepAlways; add(scope)
                XCTAssertEqual(Set(visible), Set(required))
                XCTAssertEqual(hosting.bounds.size, size)
                XCTAssertEqual(driver.checks, 0)
            }
        }
    }
}

@MainActor private final class AutomaticUpdateRenderCapture { var regions: [InstallerCaptureRegion] = [] }
@MainActor private final class SettingsUpdateFixture: AppUpdateDriving {
    var snapshot = AppUpdateSnapshot(canCheck: true, allowsAutomaticUpdates: true)
    var didChange: ((AppUpdateSnapshot) -> Void)?
    var includePreviews = true
    var checks = 0
    var failStart = false
    func start() throws { if failStart { throw CocoaError(.fileReadUnknown) } }
    func check() { checks += 1 }
    func setAutomaticChecks(_ enabled: Bool) { snapshot.checksAutomatically = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { snapshot.downloadsAutomatically = enabled }
}
