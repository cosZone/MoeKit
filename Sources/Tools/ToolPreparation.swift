import Foundation
import Observation

/// Presence is not provenance: none of these observations authorizes execution.
enum PreparedTool: String, CaseIterable, Identifiable, Sendable {
    case mole, git
    var id: String { rawValue }
    var title: String { self == .mole ? "Mole" : "Git" }
    var installCommand: String { self == .mole ? "brew install mole" : "brew install git" }
    var documentationURL: URL {
        URL(string: self == .mole ? "https://github.com/tw93/Mole#quick-start" : "https://git-scm.com/install/mac")!
    }

    /// Fixed candidates, never PATH search, shell expansion or a directory walk.
    func conventionalLocations(home: URL) -> [URL] {
        let names = self == .mole ? ["mo", "mole"] : ["git"]
        let prefixes = [URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                        URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
                        home.appendingPathComponent(".local/bin", isDirectory: true)]
        var result = prefixes.flatMap { prefix in names.map { prefix.appendingPathComponent($0) } }
        if self == .git { result.append(URL(fileURLWithPath: "/usr/bin/git")) }
        return result
    }
}

enum ToolCandidateState: Equatable, Sendable {
    case missing
    case foundUnverified(symbolicLink: Bool)
    case unsupported(ToolCandidateLimitation)
    case unreadable

    var title: String {
        switch self {
        case .missing: String(localized: "Not found at this path")
        case .foundUnverified: String(localized: "Found · unverified")
        case .unsupported: String(localized: "Unsupported candidate")
        case .unreadable: String(localized: "Could not inspect")
        }
    }

    var explanation: String {
        switch self {
        case .missing: String(localized: "Other installation locations have not been checked.")
        case .foundUnverified(symbolicLink: true): String(localized: "A symbolic link exists. Its target, tool identity and version have not been checked.")
        case .foundUnverified(symbolicLink: false): String(localized: "A regular file has executable permission bits. Its contents, tool identity and version have not been checked.")
        case .unsupported(let reason): reason.explanation
        case .unreadable: String(localized: "Metadata could not be read. This does not mean the tool is missing.")
        }
    }
}

enum ToolCandidateLimitation: Equatable, Sendable {
    case notRegularFile, notExecutable, invalidPath
    var explanation: String {
        switch self {
        case .notRegularFile: String(localized: "This location is not a regular file or a symbolic link.")
        case .notExecutable: String(localized: "This regular file has no executable permission bits.")
        case .invalidPath: String(localized: "Choose a local, absolute file path without invalid characters.")
        }
    }
}

struct ToolCandidateObservation: Identifiable, Equatable, Sendable {
    let path: String
    let state: ToolCandidateState
    let observedAt: Date
    var id: String { path }
}

protocol ToolCandidateInspecting: Sendable {
    func inspect(_ locations: [URL]) async throws -> [ToolCandidateObservation]
}

/// Session-only explicit inspection. Cancellation retains ownership until the
/// provider settles; a provider ignoring cancellation cannot publish stale data.
@MainActor @Observable
final class ToolPreparationStore {
    private(set) var observations: [PreparedTool: [ToolCandidateObservation]] = [:]
    private(set) var inspectingTool: PreparedTool?
    private(set) var isCancelling = false
    private(set) var errorMessage: String?
    private(set) var isDemoEnabled = false
    @ObservationIgnored private let inspector: any ToolCandidateInspecting
    @ObservationIgnored private var inspectionTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(inspector: any ToolCandidateInspecting = NativeToolCandidateInspector()) {
        self.inspector = inspector
    }

    var isInspecting: Bool { inspectionTask != nil }

    func inspect(_ tool: PreparedTool, locations: [URL]) {
        guard !isDemoEnabled, inspectionTask == nil else { return }
        guard !locations.isEmpty, locations.count <= NativeToolCandidateInspector.maximumLocations else { return }
        let request = UUID()
        generation = request
        inspectingTool = tool
        isCancelling = false
        errorMessage = nil
        observations[tool] = nil
        inspectionTask = Task { [weak self, inspector] in
            do {
                let result = try await inspector.inspect(locations)
                try Task.checkCancellation()
                guard let self, self.generation == request, !self.isDemoEnabled else {
                    self?.finish(); return
                }
                self.observations[tool] = result
                self.finish()
            } catch {
                guard let self else { return }
                if !(error is CancellationError), self.generation == request, !self.isDemoEnabled {
                    self.errorMessage = String(localized: "The inspection did not finish. No tool was run.")
                }
                self.finish()
            }
        }
    }

    func cancel() {
        guard inspectionTask != nil else { return }
        generation = UUID()
        isCancelling = true
        inspectionTask?.cancel()
    }

    func setDemoEnabled(_ enabled: Bool) {
        guard enabled != isDemoEnabled else { return }
        isDemoEnabled = enabled
        cancel()
        observations = [:]
        errorMessage = nil
    }

    private func finish() {
        inspectionTask = nil
        inspectingTool = nil
        isCancelling = false
    }
}
