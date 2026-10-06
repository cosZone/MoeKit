import Foundation
import Darwin
import Testing
import Observation
@testable import MoeKit

@Suite("Metadata-only tool preparation")
struct ToolPreparationTests {
    @Test("Fixed candidate lists do not depend on PATH or a shell")
    func conventionalLocations() {
        let home = URL(fileURLWithPath: "/synthetic-home", isDirectory: true)
        #expect(PreparedTool.mole.conventionalLocations(home: home).map(\.path) == [
            "/synthetic-home/" + MoleAnalyzerRelease.native.installationDirectoryName + "/analyze-go",
            "/synthetic-home/.config/mole/bin/analyze-go", "/opt/homebrew/bin/mo", "/opt/homebrew/bin/mole", "/usr/local/bin/mo",
            "/usr/local/bin/mole", "/synthetic-home/.local/bin/mo", "/synthetic-home/.local/bin/mole"])
        #expect(PreparedTool.git.conventionalLocations(home: home).map(\.path) == [
            "/opt/homebrew/bin/git", "/usr/local/bin/git", "/synthetic-home/.local/bin/git", "/usr/bin/git"])
        #expect(PreparedTool.mole.installCommand == MoleAnalyzerRelease.native.manualDownloadCommand)
        #expect(PreparedTool.git.installCommand == "brew install git")
        #expect(PreparedTool.mole.documentationURL.host == "github.com")
        #expect(PreparedTool.git.documentationURL.host == "git-scm.com")
    }

    @Test("Manual downloads use exactly the analyzer allowlist and verify before chmod")
    func compatibleDownloadGuidance() throws {
        for release in [MoleAnalyzerRelease.arm64, .x86_64] {
            let command = release.manualDownloadCommand
            let asset = release.architecture == "arm64" ? "analyze-darwin-arm64" : "analyze-darwin-amd64"
            #expect(release.assetName == asset)
            #expect(release.assetURL.absoluteString == "https://github.com/tw93/Mole/releases/download/V1.57.0/" + asset)
            #expect(release.releaseURL.absoluteString == "https://github.com/tw93/Mole/releases/tag/V1.57.0")
            #expect(command.contains("umask 077 &&"))
            #expect(command.contains(#"/usr/bin/mktemp -d "$HOME/MoeKit-Mole-download.XXXXXX""#))
            #expect(command.contains("/usr/bin/curl -q --fail --location --show-error --proto '=https' --proto-redir '=https'"))
            #expect(command.contains("--connect-timeout 15 --max-time 120 --max-filesize \(release.byteCount)"))
            let size = try #require(command.range(of: "-eq \(release.byteCount) &&"))
            let digest = try #require(command.range(of: "'\(release.sha256)'"))
            let verify = try #require(command.range(of: "/usr/bin/shasum -a 256 -c - &&"))
            let permission = try #require(command.range(of: #"/bin/chmod 700 "$mole_download/analyze-go" &&"#))
            #expect(size.upperBound < digest.lowerBound)
            #expect(digest.upperBound < verify.lowerBound)
            #expect(verify.upperBound < permission.lowerBound)
            #expect(command.contains("Analyzer path: %s"))
            #expect(command.contains("Mole analyzer ready"))
            #expect(command.contains(release.installationDirectoryName))
            #expect(command.contains(#"test -e "$mole_dir" || test -L "$mole_dir""#))
            let create = try #require(command.range(of: #"/bin/mkdir -m 700 "$mole_dir" &&"#))
            let link = try #require(command.range(of: #"/bin/ln "$mole_download/analyze-go" "$mole_dir/analyze-go""#))
            #expect(permission.upperBound < create.lowerBound)
            #expect(create.upperBound < link.lowerBound)
            for forbidden in ["brew", "install.sh", "xattr", "sudo", "rm ", "latest", "PATH=", "--json", "| bash", "| sh"] {
                #expect(!command.contains(forbidden))
            }
        }
        let home = URL(fileURLWithPath: "/synthetic-home")
        #expect(PreparedTool.mole.conventionalLocations(home: home).count <= NativeToolCandidateInspector.maximumLocations)
        #expect(PreparedTool.mole.conventionalLocationLabel(home.appendingPathComponent(".config/mole/bin/analyze-go"), home: home) == "~/.config/mole/bin/analyze-go")
    }

    @Test("Conventional location presentation never exposes the account home path")
    func homeLabelsArePrivate() {
        let home = URL(fileURLWithPath: "/Users/private-fixture-account", isDirectory: true)
        for tool in PreparedTool.allCases {
            let labels = tool.conventionalLocations(home: home).map { tool.conventionalLocationLabel($0, home: home) }
            #expect(labels.allSatisfy { !$0.contains("private-fixture-account") && !$0.contains(home.path) })
            #expect(labels.contains("~/.local/bin/" + (tool == .mole ? "mo" : "git")))
        }
    }

    @Test("Executable permissions never verify identity or execute script contents")
    func executableIsOnlyEvidence() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("arbitrary-name")
        // An executable fixture only. Never run it, even in CI.
        try Data("#!/bin/sh\nexit 73\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let start = Date()
        let result = try await NativeToolCandidateInspector().inspect([script])
        #expect(result.count == 1)
        #expect(result[0].state == .foundUnverified(symbolicLink: false))
        #expect(result[0].observedAt >= start)
        #expect(try Data(contentsOf: script) == Data("#!/bin/sh\nexit 73\n".utf8))
    }

    @Test("Missing, directory, FIFO and non-executable files have accurate states")
    func fileKinds() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing")
        let ordinary = directory.appendingPathComponent("ordinary")
        try Data("not executable".utf8).write(to: ordinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ordinary.path)
        let fifo = directory.appendingPathComponent("fifo")
        #expect(fifo.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
        let result = try await NativeToolCandidateInspector().inspect([missing, directory, ordinary, fifo])
        #expect(result.map(\.state) == [.missing, .unsupported(.notRegularFile),
                                      .unsupported(.notExecutable), .unsupported(.notRegularFile)])
    }

    @Test("Final symlinks are evidence only, including dangling links and FIFO targets")
    func symbolicLinks() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dangling = directory.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "absent")
        let fifo = directory.appendingPathComponent("fifo")
        #expect(fifo.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
        let fifoLink = directory.appendingPathComponent("fifo-link")
        try FileManager.default.createSymbolicLink(at: fifoLink, withDestinationURL: fifo)
        let result = try await NativeToolCandidateInspector().inspect([dangling, fifoLink])
        #expect(result.map(\.state) == [.foundUnverified(symbolicLink: true), .foundUnverified(symbolicLink: true)])
    }

    @Test("Inaccessible metadata stays unknown and cannot become missing")
    func inaccessibleAncestor() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loop = directory.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")
        let result = try await NativeToolCandidateInspector().inspect([loop.appendingPathComponent("tool")])
        #expect(result[0].state == .unreadable)
    }

    @Test("Invalid URLs and budgets are refused before filesystem inspection")
    func invalidInputs() async throws {
        let inspector = NativeToolCandidateInspector()
        let urls = [URL(string: "https://example.invalid/tool")!, URL(string: "file://remote.invalid/tool")!,
                    URL(fileURLWithPath: "/" + String(repeating: "x", count: Int(PATH_MAX)))]
        #expect(try await inspector.inspect(urls).map(\.state) == Array(repeating: .unsupported(.invalidPath), count: 3))
        await #expect(throws: NativeToolCandidateInspector.InspectionError.self) {
            try await inspector.inspect(Array(repeating: URL(fileURLWithPath: "/never-inspected"), count: 9))
        }
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-tool-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@Suite("Explicit tool-inspection coordination") @MainActor
struct ToolPreparationStoreTests {
    @Test("Construction performs no inspection and Demo blocks all requests")
    func explicitOnly() async {
        let inspector = ControlledToolInspector()
        let store = ToolPreparationStore(inspector: inspector)
        #expect(await inspector.count == 0)
        #expect(store.observations.isEmpty)
        store.setDemoEnabled(true)
        store.inspect(.mole, locations: [Self.location])
        #expect(await inspector.count == 0)
        #expect(!store.isInspecting)
    }

    @Test("Inspection lifecycle is observable so busy controls and cancellation stay visible")
    func observableLifecycle() async throws {
        let inspector = ControlledToolInspector()
        let store = ToolPreparationStore(inspector: inspector)
        let started = ToolObservationFlag()
        withObservationTracking { _ = store.isInspecting } onChange: { started.mark() }
        store.inspect(.mole, locations: [Self.location])
        #expect(started.value)
        await inspector.waitForStart()
        let finished = ToolObservationFlag()
        withObservationTracking { _ = store.isInspecting } onChange: { finished.mark() }
        await inspector.complete()
        try await settle(store)
        #expect(finished.value)
    }

    @Test("Duplicate starts and cancellation keep one owned operation until settlement")
    func cancellationOwnership() async throws {
        let inspector = ControlledToolInspector()
        let store = ToolPreparationStore(inspector: inspector)
        store.inspect(.mole, locations: [Self.location])
        await inspector.waitForStart()
        store.inspect(.git, locations: [Self.location])
        store.cancel()
        store.inspect(.git, locations: [Self.location])
        #expect(store.isInspecting)
        #expect(store.isCancelling)
        #expect(await inspector.count == 1)
        await inspector.complete()
        try await settle(store)
        #expect(store.observations.isEmpty)
        #expect(!store.isCancelling)
    }

    @Test("Mode changes discard stale results even when the provider ignores cancellation")
    func modeBoundary() async throws {
        let inspector = ControlledToolInspector()
        let store = ToolPreparationStore(inspector: inspector)
        store.inspect(.mole, locations: [Self.location])
        await inspector.waitForStart()
        store.setDemoEnabled(true)
        store.setDemoEnabled(false)
        store.inspect(.git, locations: [Self.location])
        #expect(await inspector.count == 1)
        await inspector.complete()
        try await settle(store)
        #expect(store.observations.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test("Workspace mode transitions synchronously invalidate inspection and picker tickets")
    func workspaceRapidRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-tool-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inspector = ControlledToolInspector()
        let preparation = ToolPreparationStore(inspector: inspector)
        let workspace = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory), toolPreparation: preparation)
        let pickerTicket = preparation.modeGeneration
        preparation.inspect(.mole, locations: [Self.location])
        await inspector.waitForStart()
        // No suspension or SwiftUI render between these transitions.
        workspace.isDemoEnabled = true
        workspace.isDemoEnabled = false
        #expect(preparation.modeGeneration != pickerTicket)
        #expect(preparation.isCancelling)
        await inspector.complete()
        try await settle(preparation)
        #expect(preparation.observations.isEmpty)
        // An old chooser cannot launch an inspection after the old IO settles.
        preparation.inspect(.git, locations: [Self.location], expectedMode: pickerTicket)
        #expect(!preparation.isInspecting)
        #expect(await inspector.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("Explicit Demo workspace initializes tool preparation disabled")
    func workspaceStartsInDemo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-tool-demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = WorkspaceStore(isDemoEnabled: true, persistence: CatalogPersistence(directory: directory))
        #expect(workspace.toolPreparation.isDemoEnabled)
        workspace.toolPreparation.inspect(.mole, locations: [Self.location])
        #expect(!workspace.toolPreparation.isInspecting)
    }

    @Test("A new explicit inspection replaces old metadata rather than showing it as fresh")
    func refresh() async throws {
        let inspector = ControlledToolInspector()
        let store = ToolPreparationStore(inspector: inspector)
        store.inspect(.mole, locations: [Self.location])
        await inspector.waitForStart()
        await inspector.complete()
        try await settle(store)
        #expect(store.observations[.mole]?.first?.state == .foundUnverified(symbolicLink: false))
        store.inspect(.mole, locations: [Self.location])
        #expect(store.observations[.mole] == nil)
        await inspector.waitForStart()
        await inspector.fail()
        try await settle(store)
        #expect(store.observations[.mole] == nil)
        #expect(store.errorMessage != nil)
    }

    @Test("Mode changes clear finished metadata and invalid request sizes never start")
    func clearAndBounds() async throws {
        let inspector = ControlledToolInspector()
        let store = ToolPreparationStore(inspector: inspector)
        store.inspect(.mole, locations: [])
        store.inspect(.mole, locations: Array(repeating: Self.location, count: 9))
        #expect(await inspector.count == 0)
        store.inspect(.mole, locations: [Self.location])
        await inspector.waitForStart()
        await inspector.complete()
        try await settle(store)
        store.setDemoEnabled(true)
        #expect(store.observations.isEmpty)
    }

    private static let location = URL(fileURLWithPath: "/synthetic/tool")
    private func settle(_ store: ToolPreparationStore) async throws {
        for _ in 0..<1_000 {
            if !store.isInspecting { return }
            await Task.yield()
        }
        throw ToolTestFailure.didNotSettle
    }
}

private enum ToolTestFailure: Error { case synthetic, didNotSettle }
private actor ControlledToolInspector: ToolCandidateInspecting {
    private(set) var count = 0
    private var continuation: CheckedContinuation<[ToolCandidateObservation], any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func inspect(_ locations: [URL]) async throws -> [ToolCandidateObservation] {
        count += 1
        return try await withCheckedThrowingContinuation {
            continuation = $0
            started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func complete() {
        continuation?.resume(returning: [ToolCandidateObservation(path: "/synthetic/tool", state: .foundUnverified(symbolicLink: false), observedAt: Date())])
        continuation = nil
    }
    func fail() {
        continuation?.resume(throwing: ToolTestFailure.synthetic)
        continuation = nil
    }
}

/// A lock-protected observation signal; callbacks may arrive on any executor.
private final class ToolObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.lock(); defer { lock.unlock() }; marked = true }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return marked }
}
