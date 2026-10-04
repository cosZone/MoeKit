import AppKit
import SwiftUI
import XCTest
@testable import MoeKit

/// Synthetic owned-view evidence. No user paths, process launch or screen capture.
final class MoleAnalysisViewTests: XCTestCase {
    @MainActor
    func testAnalysisSheetRenders() async throws {
        for scenario in ["initial", "confirmation", "partial", "failure"] {
            for dark in [false, true] {
                for size in [NSSize(width: 720, height: 560), NSSize(width: 900, height: 800)] {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-analysis-render-\(UUID())")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let analysis = MoleAnalysisStore(executor: RenderMoleAnalyzer(failure: scenario == "failure"))
                    let workspace = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory), moleAnalysis: analysis)
                    if scenario != "initial" {
                        analysis.selectExecutable(URL(fileURLWithPath: "/Synthetic/OfficialMole/bin/analyze-go"), ticket: try XCTUnwrap(analysis.selectionTicket()))
                        analysis.selectDirectory(URL(fileURLWithPath: "/Synthetic/Projects/Selected project with a long directory name"), ticket: try XCTUnwrap(analysis.selectionTicket()))
                        analysis.prepare()
                        for _ in 0..<1000 { if !analysis.isBusy { break }; await Task.yield() }
                        XCTAssertFalse(analysis.isBusy)
                        if scenario != "confirmation" {
                            analysis.confirm(planID: try XCTUnwrap(analysis.plan?.id))
                            for _ in 0..<1000 { if !analysis.isBusy { break }; await Task.yield() }
                            XCTAssertFalse(analysis.isBusy)
                        }
                    }
                    let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
                    XCTAssertTrue(["en", "zh-Hans"].contains(language))
                    let name = "mole-analysis-\(scenario)-\(language)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
                    _ = NSApplication.shared
                    let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                    let root = MoleAnalysisView().environment(workspace)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.locale, Locale.current)
                        .frame(width: size.width, height: size.height)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let hosting = NSHostingView(rootView: root)
                    hosting.sizingOptions = []
                    hosting.frame = NSRect(origin: .zero, size: size)
                    hosting.appearance = appearance
                    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = hosting
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
                    attachment.name = name + ".png"; attachment.lifetime = .keepAlways; add(attachment)
                    let metadata = XCTAttachment(string: """
                    Content size: \(Int(size.width)) × \(Int(size.height)) points
                    Process locale: \(Locale.current.identifier)
                    Bundle language: \(language)
                    Projects title: \(WorkspaceSection.projects.title)
                    Partial-result title: \(TaskStatus.partial.title)
                    Scope: owned analysis sheet with synthetic paths and reports only.
                    Scenario: \(scenario). No real analyzer, installation, network, or user path access.
                    The sheet has a vertical scroll container so confirmation controls remain reachable at minimum size.
                    These images are review evidence, not native interaction or accessibility acceptance.
                    """)
                    metadata.name = name + "-scope.txt"; metadata.lifetime = .keepAlways; add(metadata)
                    XCTAssertGreaterThan(png.count, 1000)
                    XCTAssertFalse(analysis.isBusy)
                }
            }
        }
    }
}

private struct RenderMoleAnalyzer: MoleAnalysisExecuting {
    let failure: Bool
    func prepare(executable: URL, directory: URL) async throws -> MoleAnalysisPlan {
        MoleAnalysisPlan(id: UUID(), executable: executable, directory: directory,
                         executableIdentity: MoleFileIdentity(device: 1, inode: 2), directoryIdentity: MoleFileIdentity(device: 1, inode: 3),
                         release: .native, preparedAt: Date(),
                         privateSessionParent: URL(fileURLWithPath: "/Synthetic/Library/Caches/com.yusixian.MoeKit.MoleAnalysis"))
    }
    func run(_ plan: MoleAnalysisPlan) async throws -> MoleAnalysisResult {
        if failure { throw MoleAnalysisFailure.timeLimit }
        let data = try JSONSerialization.data(withJSONObject: ["path":plan.directory.path,"overview":false,"scan_status":"partial","total_size":4096,
            "entries":[["path":plan.directory.path+"/Build","name":"Build","is_dir":true,"size":4096,"scan_status":"partial"],
                       ["path":plan.directory.path+"/Restricted","name":"Restricted","is_dir":true,"size":0,"scan_status":"unavailable"]]])
        return MoleAnalysisResult(report: try JSONDecoder().decode(MoleAnalyzeReport.self, from: data), directory: plan.directory,
                                  release: plan.release, startedAt: Date(timeIntervalSince1970: 1_791_100_800),
                                  finishedAt: Date(timeIntervalSince1970: 1_791_100_801))
    }
}
