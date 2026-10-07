import AppKit
import SwiftUI
import XCTest
@testable import MoeKit

/// Synthetic owned-view evidence. No user paths, process launch or screen capture.
final class MoleAnalysisViewTests: XCTestCase {
    @MainActor
    func testAnalysisSheetRenders() async throws {
        for scenario in ["initial", "ready", "missing", "incompatible", "unverified", "advanced", "guide", "confirmation", "partial", "failure",
                         "homebrew-ready", "current-unverified", "unsupported-format", "unsupported-architecture", "unknown-version",
                         "untested-confirmation", "untested-result"] {
            for dark in [false, true] {
                let sizes: [NSSize] = scenario == "guide" ? [NSSize(width: 720, height: 1400)] :
                    (scenario.hasPrefix("untested-") ? [NSSize(width: 720, height: 1400), NSSize(width: 900, height: 1600)] :
                     [NSSize(width: 720, height: 560), NSSize(width: 900, height: 800)])
                for size in sizes {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-analysis-render-\(UUID())")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let discovery = RenderMoleDiscovery(scenario: scenario)
                    let release = scenario.hasPrefix("untested-") ? RenderMoleFixture.untestedRelease : MoleAnalyzerRelease.native
                    let analysis = MoleAnalysisStore(executor: RenderMoleAnalyzer(failure: scenario == "failure", release: release),
                        discovery: discovery, homebrewVerifier: RenderMoleHomebrewVerifier())
                    let workspace = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory), moleAnalysis: analysis)
                    if ["confirmation", "partial", "failure", "untested-confirmation", "untested-result"].contains(scenario) {
                        if scenario.hasPrefix("untested-") {
                            analysis.discoverIfNeeded()
                            for _ in 0..<1000 { if !analysis.isBusy { break }; await Task.yield() }
                            XCTAssertFalse(analysis.isBusy)
                        } else {
                            analysis.selectExecutable(URL(fileURLWithPath: "/Synthetic/OfficialMole/bin/analyze-go"), ticket: try XCTUnwrap(analysis.selectionTicket()))
                        }
                        analysis.selectDirectory(URL(fileURLWithPath: "/Synthetic/Projects/Selected project with a long directory name"), ticket: try XCTUnwrap(analysis.selectionTicket()))
                        analysis.prepare()
                        for _ in 0..<1000 { if !analysis.isBusy { break }; await Task.yield() }
                        XCTAssertFalse(analysis.isBusy)
                        if !["confirmation", "untested-confirmation"].contains(scenario) {
                            analysis.confirm(planID: try XCTUnwrap(analysis.plan?.id), acknowledgeUntestedBuild: scenario == "untested-result")
                            for _ in 0..<1000 { if !analysis.isBusy { break }; await Task.yield() }
                            XCTAssertFalse(analysis.isBusy)
                        }
                    }
                    if !["initial", "confirmation", "partial", "failure", "untested-confirmation", "untested-result"].contains(scenario) {
                        analysis.discoverIfNeeded()
                        for _ in 0..<1000 { if !analysis.isBusy { break }; await Task.yield() }
                        XCTAssertFalse(analysis.isBusy)
                    }
                    if scenario == "untested-confirmation" {
                        XCTAssertTrue(try XCTUnwrap(analysis.plan).release.requiresUntestedConsent)
                        XCTAssertNil(analysis.result)
                    }
                    if scenario == "untested-result" {
                        XCTAssertTrue(try XCTUnwrap(analysis.result).release.requiresUntestedConsent)
                        XCTAssertNil(analysis.liveResultID, "Untested results must remain view-only")
                    }
                    let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
                    XCTAssertTrue(["en", "zh-Hans"].contains(language))
                    let name = "mole-analysis-\(scenario)-\(language)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
                    _ = NSApplication.shared
                    let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                    let content: AnyView = scenario == "guide"
                        ? AnyView(MoleInstallationGuidanceView(onRecheck: {}, showsDownloadInstructions: true).padding(20))
                        : AnyView(MoleAnalysisView(showsAdvanced: scenario == "advanced").environment(workspace))
                    XCTAssertEqual(MoleSetupText.localized("Ready to analyze"), language == "zh-Hans" ? "可以开始分析" : "Ready to analyze")
                    let root = content
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
                    Setup ready title: \(MoleSetupText.localized("Ready to analyze"))
                    Scope: owned analysis sheet with synthetic paths and reports only.
                    Scenario: \(scenario). No real analyzer, installation, network, or user path access.
                    The sheet has a vertical scroll container so confirmation controls remain reachable at minimum size.
                    These images are review evidence, not native interaction or accessibility acceptance.
                    """)
                    metadata.name = name + "-scope.txt"; metadata.lifetime = .keepAlways; add(metadata)
                    XCTAssertGreaterThan(png.count, 1000)
                    if scenario == "initial" {
                        XCTAssertTrue(analysis.isDiscovering)
                        analysis.cancel()
                        for _ in 0..<1000 { if !analysis.isBusy { break }; await Task.yield() }
                    }
                    XCTAssertFalse(analysis.isBusy)
                }
            }
        }
    }
}

private struct RenderMoleAnalyzer: MoleAnalysisExecuting {
    let failure: Bool
    let release: MoleAnalyzerRelease
    func prepare(executable: URL, directory: URL) async throws -> MoleAnalysisPlan {
        MoleAnalysisPlan(id: UUID(), executable: executable, directory: directory,
                         executableIdentity: MoleFileIdentity(device: 1, inode: 2), directoryIdentity: MoleFileIdentity(device: 1, inode: 3),
                         release: release, preparedAt: Date(),
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

/// These fixtures describe UI states only; no analyzer or network call is used.
private enum RenderMoleFixture {
    static var untestedRelease: MoleAnalyzerRelease {
        let bottleSHA = String(repeating: "b", count: 64)
        return MoleAnalyzerRelease(version: "V1.59.0", architecture: MoleAnalyzerRelease.nativeArchitecture,
            byteCount: 12, sha256: String(repeating: "a", count: 64), origin: .verifiedHomebrewBottle,
            onlineProof: MoleOnlineArtifactProof(verifiedAt: Date(), bottleSHA256: bottleSHA,
                bottleURL: URL(string: "https://ghcr.io/v2/homebrew/core/mole/blobs/sha256:" + bottleSHA)!))
    }

    static func candidate(for scenario: String) -> MoleInstallationCandidate {
        let prefix = URL(fileURLWithPath: MoleAnalyzerRelease.nativeArchitecture == "arm64" ? "/opt/homebrew" : "/usr/local")
        let homebrewPath = prefix.appendingPathComponent("Cellar/mole/1.58.0/libexec/bin/analyze-go").path
        let observation = MoleAnalysisFiles.AnalyzerObservation(identity: MoleFileIdentity(device: 1, inode: 2),
            byteCount: 12, sha256: String(repeating: "a", count: 64))
        var candidate = MoleInstallationCandidate(path: "/Synthetic/OfficialMole/bin/analyze-go", state: .usable,
            source: String(localized: "Official analyzer location"),
            explanation: String(localized: "The analyzer matches a tested official build. It will be verified again before analysis."),
            verifiedRelease: .native, origin: .official)
        switch scenario {
        case "missing", "guide", "initial":
            candidate = MoleInstallationCandidate(path: candidate.path, state: .missing, source: candidate.source,
                explanation: String(localized: "No analyzer was found at this location. Custom locations have not been searched."))
        case "homebrew-ready":
            candidate = MoleInstallationCandidate(path: homebrewPath, state: .usable,
                source: String(localized: "Homebrew installation"), explanation: candidate.explanation,
                declaredVersion: "1.58.0", verifiedRelease: .native, origin: .homebrew(prefix: prefix),
                kegVersion: "1.58.0", isHomebrewCore: true)
        case "untested-confirmation", "untested-result":
            candidate = MoleInstallationCandidate(path: prefix.appendingPathComponent("Cellar/mole/1.59.0/libexec/bin/analyze-go").path,
                state: .unverified, source: String(localized: "Homebrew installation"),
                explanation: MoleInstallationIssue.untestedVersion.explanation, declaredVersion: "1.59.0",
                verifiedRelease: untestedRelease, origin: .homebrew(prefix: prefix), issue: .untestedVersion,
                observation: observation, kegVersion: "1.59.0", isHomebrewCore: true)
        case "current-unverified":
            candidate = MoleInstallationCandidate(path: homebrewPath, state: .unverified,
                source: String(localized: "Homebrew installation"), explanation: MoleInstallationIssue.unverifiedBuild.explanation,
                declaredVersion: "1.58.0", origin: .homebrew(prefix: prefix), issue: .unverifiedBuild,
                observation: observation, kegVersion: "1.58.0", isHomebrewCore: true)
        case "unsupported-format":
            candidate = MoleInstallationCandidate(path: prefix.appendingPathComponent("Cellar/mole/1.50.0/libexec/bin/analyze-go").path,
                state: .incompatible, source: String(localized: "Homebrew installation"),
                explanation: MoleInstallationIssue.unsupportedFormat.explanation, declaredVersion: "1.50.0",
                origin: .homebrew(prefix: prefix), issue: .unsupportedFormat,
                observation: observation, kegVersion: "1.50.0", isHomebrewCore: true)
        case "unsupported-architecture", "incompatible":
            candidate = MoleInstallationCandidate(path: candidate.path, state: .incompatible, source: candidate.source,
                explanation: MoleInstallationIssue.unsupportedArchitecture.explanation,
                declaredVersion: "1.58.0", origin: .official, issue: .unsupportedArchitecture)
        case "unknown-version":
            candidate = MoleInstallationCandidate(path: candidate.path, state: .unverified, source: candidate.source,
                explanation: MoleInstallationIssue.missingVersion.explanation, origin: .official, issue: .missingVersion)
        case "unverified":
            candidate = MoleInstallationCandidate(path: candidate.path, state: .unverified, source: candidate.source,
                explanation: MoleInstallationIssue.quarantine.explanation, origin: .official, issue: .quarantine)
        default: break
        }
        return candidate
    }
}

private struct RenderMoleDiscovery: MoleInstallationDiscovering {
    let scenario: String
    func discover() async throws -> MoleInstallationReport {
        if scenario == "initial" { try await Task.sleep(for: .seconds(30)) }
        return MoleInstallationReport(candidates: [RenderMoleFixture.candidate(for: scenario)],
            inspectedAt: Date(timeIntervalSince1970: 1_791_100_800))
    }
}

private struct RenderMoleHomebrewVerifier: MoleHomebrewVerifying {
    func verify(expectedVersion: String, architecture: String,
                installedByteCount: Int, installedSHA256: String) async throws -> MoleHomebrewEvidence {
        // Rendering must never activate online verification.
        throw MoleHomebrewVerificationFailure.unavailable
    }
}
