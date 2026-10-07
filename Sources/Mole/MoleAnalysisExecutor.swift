import Darwin
import Foundation

protocol MoleAnalysisExecuting: Sendable {
    func prepare(executable: URL, directory: URL) async throws -> MoleAnalysisPlan
    func run(_ plan: MoleAnalysisPlan) async throws -> MoleAnalysisResult
    func prepare(executable: URL, directory: URL, verifiedArtifact: MoleAnalyzerRelease?) async throws -> MoleAnalysisPlan
    func run(_ plan: MoleAnalysisPlan, acknowledgeUntestedBuild: Bool) async throws -> MoleAnalysisResult
}

extension MoleAnalysisExecuting {
    func prepare(executable: URL, directory: URL, verifiedArtifact: MoleAnalyzerRelease?) async throws -> MoleAnalysisPlan {
        try await prepare(executable: executable, directory: directory)
    }
    func run(_ plan: MoleAnalysisPlan, acknowledgeUntestedBuild: Bool) async throws -> MoleAnalysisResult {
        guard !plan.release.requiresUntestedConsent || acknowledgeUntestedBuild else { throw MoleAnalysisFailure.untestedConsentRequired }
        return try await run(plan)
    }
}

/// Executes exact reviewed artifacts, or freshly bottle-verified official
/// builds with separate per-run untested acknowledgement. The bundled
/// supervisor bounds lifecycle/output; this is not an OS sandbox.
actor MoleAnalysisExecutor: MoleAnalysisExecuting {
    private let sessionParentOverride: URL?
    init(privateSessionParent: URL? = nil) { sessionParentOverride = privateSessionParent }
    func prepare(executable: URL, directory: URL) async throws -> MoleAnalysisPlan {
        try await prepare(executable: executable, directory: directory, verifiedArtifact: nil)
    }
    func prepare(executable: URL, directory: URL, verifiedArtifact: MoleAnalyzerRelease?) async throws -> MoleAnalysisPlan {
        try Task.checkCancellation()
        try MoleAnalysisFiles.validateLocalURL(executable)
        try MoleAnalysisFiles.validateLocalURL(directory)
        // Reject final symlinks before resolving macOS ancestor aliases.
        for selection in [executable, directory] {
            var info = stat()
            guard lstat(selection.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
                throw MoleAnalysisFailure.invalidSelection
            }
        }
        let binary = try MoleAnalysisFiles.canonicalURL(executable)
        let scope = try MoleAnalysisFiles.canonicalURL(directory)
        let parent = try sessionParentOverride ?? MoleAnalysisFiles.privateParent()
        guard scope.path != "/", !MoleLiveReportValidator.overlaps(scope, parent),
              !MoleLiveReportValidator.overlaps(binary, parent) else { throw MoleAnalysisFailure.invalidSelection }
        let binaryFD = try MoleAnalysisFiles.openPath(binary, directory: false)
        defer { close(binaryFD) }
        let observation = try MoleAnalysisFiles.observeAnalyzer(binaryFD)
        let known = MoleAnalyzerRelease.nativeArtifacts.first { $0.sha256 == observation.sha256 && $0.byteCount == observation.byteCount }
        guard let release = known ?? verifiedArtifact, release.isEligible else { throw MoleAnalysisFailure.unsupportedBinary }
        let executableIdentity = try MoleAnalysisFiles.verifyAnalyzer(binaryFD, release: release)
        let scopeFD = try MoleAnalysisFiles.openDirectory(scope)
        defer { close(scopeFD) }
        return MoleAnalysisPlan(id: UUID(), executable: binary, directory: scope,
                                executableIdentity: executableIdentity,
                                directoryIdentity: try MoleAnalysisFiles.identity(scopeFD),
                                release: release, preparedAt: Date(), privateSessionParent: parent)
    }

    func run(_ plan: MoleAnalysisPlan) async throws -> MoleAnalysisResult {
        try await run(plan, acknowledgeUntestedBuild: false)
    }
    func run(_ plan: MoleAnalysisPlan, acknowledgeUntestedBuild: Bool) async throws -> MoleAnalysisResult {
        try Task.checkCancellation()
        guard !plan.release.requiresUntestedConsent || acknowledgeUntestedBuild else { throw MoleAnalysisFailure.untestedConsentRequired }
        guard plan.release.isEligible, Date().timeIntervalSince(plan.preparedAt) < 300,
              !MoleLiveReportValidator.overlaps(plan.directory, plan.privateSessionParent) else {
            throw MoleAnalysisFailure.changedSelection
        }
        let sourceFD = try MoleAnalysisFiles.openPath(plan.executable, directory: false)
        defer { close(sourceFD) }
        guard try MoleAnalysisFiles.verifyAnalyzer(sourceFD, release: plan.release) == plan.executableIdentity else {
            throw MoleAnalysisFailure.changedSelection
        }
        let scopeFD = try MoleAnalysisFiles.openDirectory(plan.directory)
        defer { close(scopeFD) }
        guard try MoleAnalysisFiles.identity(scopeFD) == plan.directoryIdentity else { throw MoleAnalysisFailure.changedSelection }
        guard let supervisor = Bundle.main.url(forAuxiliaryExecutable: "MoleAnalysisSupervisor") else {
            throw MoleAnalysisFailure.supervisorUnavailable
        }
        let session = try MolePrivateSession(parent: plan.privateSessionParent, sourceFD: sourceFD, release: plan.release)
        let started = Date()
        let output: Data
        do {
            output = try await MoleSupervisorInvocation.run(executable: supervisor, analyzer: session.executable,
                                                          directory: plan.directory, home: session.home)
            try Task.checkCancellation()
            let report = try MoleLiveReportValidator.decode(output, selectedDirectory: plan.directory)
            try MoleAnalysisFiles.verifyReportPaths(report, root: plan.directory, identity: plan.directoryIdentity)
            try session.cleanup()
            return MoleAnalysisResult(report: report, directory: plan.directory, release: plan.release,
                                      startedAt: started, finishedAt: Date())
        } catch {
            do { try session.cleanup() }
            catch { throw MoleAnalysisFailure.cleanupIncomplete }
            throw error
        }
    }
}

/// NSLock protects the sole cancellation channel. Cancellation closes stdin; it
/// never signals a PID. The native supervisor owns termination and reaping.
private final class MoleSupervisorCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var input: FileHandle?
    private var cancelled = false
    func install(_ input: FileHandle) {
        lock.lock()
        if cancelled { try? input.close() } else { self.input = input }
        lock.unlock()
    }
    func cancel() {
        lock.lock(); cancelled = true
        try? input?.close(); input = nil
        lock.unlock()
    }
    func finish() { lock.lock(); try? input?.close(); input = nil; lock.unlock() }
}

private enum MoleSupervisorInvocation {
    static func run(executable: URL, analyzer: URL, directory: URL, home: URL) async throws -> Data {
        let cancellation = MoleSupervisorCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try await invoke(executable: executable, analyzer: analyzer, directory: directory, home: home, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func invoke(executable: URL, analyzer: URL, directory: URL, home: URL,
                               cancellation: MoleSupervisorCancellation) async throws -> Data {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = [analyzer.path, directory.path, home.path]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "HOME": home.path, "TMPDIR": home.appendingPathComponent("tmp").path]
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        cancellation.install(input.fileHandleForWriting)
        defer { cancellation.finish() }
        try process.run()
        // Drain both pipes concurrently. The supervisor caps total output before
        // emitting it; these independent caps also distrust a corrupted helper.
        let stderrTask = Task.detached(priority: .utility) {
            try drain(errors.fileHandleForReading, maximum: 64 * 1024, cancellation: cancellation)
        }
        let bytes: Data
        do { bytes = try drain(output.fileHandleForReading, maximum: MoleLiveReportValidator.maximumBytes, cancellation: cancellation) }
        catch {
            cancellation.cancel()
            process.waitUntilExit()
            _ = try? await stderrTask.value
            throw error
        }
        process.waitUntilExit()
        // stderr is bounded and deliberately not copied into task history/UI.
        _ = try await stderrTask.value
        guard process.terminationReason == .exit else { throw MoleAnalysisFailure.processFailed }
        switch process.terminationStatus {
        case 0: return bytes
        case 71: throw MoleAnalysisFailure.outputLimit
        case 72: throw MoleAnalysisFailure.timeLimit
        case 74: throw MoleAnalysisFailure.cancelled
        default: throw MoleAnalysisFailure.processFailed
        }
    }

    private static func drain(_ handle: FileHandle, maximum: Int, cancellation: MoleSupervisorCancellation) throws -> Data {
        defer { try? handle.close() }
        var data = Data()
        while let next = try handle.read(upToCount: 64 * 1024), !next.isEmpty {
            guard next.count <= maximum - data.count else { cancellation.cancel(); throw MoleAnalysisFailure.outputLimit }
            data.append(next)
        }
        return data
    }
}
