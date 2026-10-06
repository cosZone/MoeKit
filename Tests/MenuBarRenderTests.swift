import AppKit
import SwiftUI
import XCTest
@testable import MoeKit

/// Only owned offscreen views and original template artwork. These are review
/// artifacts, not screenshots of the menu bar or VoiceOver/interaction proof.
final class MenuBarRenderTests: XCTestCase {
    @MainActor
    func testMenuBarPanelStatesRender() async throws {
        _ = NSApplication.shared
        let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
        XCTAssertTrue(["en", "zh-Hans"].contains(language))
        XCTAssertEqual(MenuBarText.localized("Ready"), language == "zh-Hans" ? "就绪" : "Ready")
        XCTAssertEqual(MenuBarText.localized("Open MoeKit"), language == "zh-Hans" ? "打开 MoeKit" : "Open MoeKit")
        for kind in MenuBarActivity.allCases {
            for dark in [false, true] {
                let presentation = MenuBarPresentation()
                presentation.snapshot = .init(activity: kind, taskTitle: kind == .busy
                    ? (language == "zh-Hans" ? "项目发现 · 较长的示例任务名称" : "Discover projects · a long synthetic task name") : nil)
                let size = MenuBarPanelView.size
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                let root = MenuBarPanelView(presentation: presentation, openWorkspace: {}, openSettings: {}, checkUpdates: {}, quit: {}, close: {})
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.locale, Locale.current)
                    .environment(\.accessibilityReduceMotion, true)
                    .background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: root)
                hosting.sizingOptions = []
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.appearance = appearance
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = hosting
                defer { window.contentView = nil; window.close() }
                for _ in 0..<5 {
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                    window.setContentSize(size)
                }
                XCTAssertEqual(hosting.bounds.size, size)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = "menubar-panel-\(kind.rawValue)-\(language)-\(dark ? "dark" : "light")-328x304"
                attach(png, name: name)
                let metadata = XCTAttachment(string: """
                Content size: 328 × 304 points
                Bundle language: \(language)
                Ready title: \(MenuBarText.localized("Ready"))
                Open title: \(MenuBarText.localized("Open MoeKit"))
                Scope: original owned menu-bar panel with synthetic status only; no scan, user data, network or screen capture.
                State: \(kind.rawValue); reduced motion enabled. No real system menu bar or focus interaction was captured.
                These renders require visual review; they are not pixel baselines or accessibility acceptance.
                """)
                metadata.name = name + "-scope.txt"; metadata.lifetime = .keepAlways; add(metadata)
                XCTAssertGreaterThan(png.count, 1000)
            }
        }
    }

    @MainActor
    func testTemplateFramesRenderAtBothScales() throws {
        _ = NSApplication.shared
        for scale in [1, 2] {
            // All activity badges plus the complete one-shot animation are
            // reviewable at native 1x and Retina 2x, in both menu-bar inks.
            for dark in [false, true] {
                let columns = MenuBarIcon.frameCount + 1
                let points = NSSize(width: CGFloat(columns * 28), height: CGFloat(MenuBarActivity.allCases.count * 28))
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(points.width) * scale, pixelsHigh: Int(points.height) * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                (dark ? NSColor.black : NSColor.white).setFill()
                NSRect(origin: .zero, size: points).fill()
                for (row, kind) in MenuBarActivity.allCases.enumerated() {
                    for frame in 0...MenuBarIcon.frameCount {
                        let rect = NSRect(x: CGFloat(frame * 28 + 3), y: CGFloat(row * 28 + 3), width: 22, height: 22)
                        // Isolate tint compositing to this glyph, preserving the
                        // background exactly as a template control would.
                        context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
                        MenuBarIcon.image(activity: kind, frame: frame).draw(in: rect)
                        (dark ? NSColor.white : NSColor.black).setFill()
                        rect.fill(using: .sourceIn)
                        context.cgContext.endTransparencyLayer()
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                attach(png, name: "menubar-frames-\(dark ? "dark" : "light")-\(scale)x")
                XCTAssertGreaterThan(png.count, 1000)
            }
        }
    }

    private func attach(_ png: Data, name: String) {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name + ".png"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
