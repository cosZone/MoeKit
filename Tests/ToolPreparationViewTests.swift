import AppKit
import SwiftUI
import XCTest
@testable import MoeKit

/// Owned-view evidence only. No tool is installed, probed, executed or discovered.
final class ToolPreparationViewTests: XCTestCase {
    @MainActor
    func testToolPreparationRenders() async throws {
        for scenario in ["unchecked", "observed", "demo"] {
            let preparation = ToolPreparationStore(inspector: RenderToolInspector())
            if scenario == "demo" { preparation.setDemoEnabled(true) }
            if scenario == "observed" {
                preparation.inspect(.mole, locations: [URL(fileURLWithPath: "/synthetic/mo")])
                for _ in 0..<1_000 {
                    if !preparation.isInspecting { break }
                    await Task.yield()
                }
                XCTAssertFalse(preparation.isInspecting)
            }
            for dark in [false, true] {
                for size in [NSSize(width: 580, height: 520), NSSize(width: 680, height: 720)] {
                    let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
                    XCTAssertTrue(["en", "zh-Hans"].contains(language))
                    XCTAssertEqual(ToolCandidateState.foundUnverified(symbolicLink: true).title, language == "zh-Hans" ? "已找到 · 未验证" : "Found · unverified")
                    let name = "tool-preparation-\(scenario)-\(language)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
                    _ = NSApplication.shared
                    let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                    let root = ToolPreparationView(preparation: preparation,
                        homeDirectory: URL(fileURLWithPath: "/Users/private-fixture-account"),
                        showsLocations: scenario == "demo")
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.locale, Locale.current)
                        .frame(width: size.width, height: size.height)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let hosting = NSHostingView(rootView: root)
                    hosting.sizingOptions = []
                    hosting.frame = NSRect(origin: .zero, size: size)
                    hosting.appearance = appearance
                    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = appearance
                    window.contentView = hosting
                    defer { window.contentView = nil; window.close() }
                    for _ in 0..<5 {
                        hosting.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(50))
                        window.setContentSize(size)
                    }
                    XCTAssertEqual(hosting.bounds.size, size)
                    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = name + ".png"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    let metadata = XCTAttachment(string: """
                    Content size: \(Int(size.width)) × \(Int(size.height)) points
                    Process locale: \(Locale.current.identifier)
                    Bundle language: \(language)
                    Projects title: \(WorkspaceSection.projects.title)
                    Partial-result title: \(TaskStatus.partial.title)
                    Tool candidate title: \(ToolCandidateState.foundUnverified(symbolicLink: true).title)
                    Scope: owned tool-preparation view, synthetic paths and observations only.
                    Scenario: \(scenario). No real tool inspection, installation or execution.
                    No screen capture, native interaction or accessibility acceptance claimed.
                    """)
                    metadata.name = name + "-scope.txt"
                    metadata.lifetime = .keepAlways
                    add(metadata)
                    XCTAssertGreaterThan(png.count, 1_000)
                    XCTAssertFalse(preparation.isInspecting)
                }
            }
        }
    }
}

private struct RenderToolInspector: ToolCandidateInspecting {
    func inspect(_ locations: [URL]) async throws -> [ToolCandidateObservation] {
        [ToolCandidateObservation(path: "/synthetic/mo", state: .foundUnverified(symbolicLink: true), observedAt: Date(timeIntervalSince1970: 1_791_100_800)),
         ToolCandidateObservation(path: "/synthetic/mole", state: .missing, observedAt: Date(timeIntervalSince1970: 1_791_100_800))]
    }
}
