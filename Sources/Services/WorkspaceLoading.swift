import Foundation

/// Narrow injectable read-only boundaries; production still uses the existing
/// actors. Test providers can deliberately return after cancellation.
protocol WorkspaceRepositoryScanning: Sendable {
    func scan(roots: [URL], options: ScanOptions,
              progress: (@Sendable (RepositoryScanProgress) async -> Void)?) async throws -> RepositoryScanResult
    func inspectFolder(_ url: URL) async throws -> RepositoryScanResult
}

extension RepositoryScanner: WorkspaceRepositoryScanning {}

protocol WorkspaceReportImporting: Sendable {
    func load(_ url: URL) async throws -> MoleAnalyzeReport
}

extension MoleReportImporter: WorkspaceReportImporting {}
