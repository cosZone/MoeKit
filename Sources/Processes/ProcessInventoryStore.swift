import Darwin
import Foundation
import Observation

/// Resolve only already-added catalog roots. Discovery does not inspect argv,
/// environment, browser profiles or project files to manufacture association.
struct ProcessProjectResolution: Sendable {
    let scopes: [ProcessProjectScope]
    let unavailableCount: Int
}

actor ProcessProjectResolver {
    func resolve(_ projects: [ProjectRecord]) throws -> ProcessProjectResolution {
        let candidates = projects.filter { $0.kind != .group }
        let scopes: [ProcessProjectScope] = try candidates.compactMap { project in
            try Task.checkCancellation()
            guard ProcessPath.isCanonicalAbsolute(project.path), project.path != "/" else { return nil }
            // Use the same physical-path representation as native cwd reads.
            // Foundation standardization may remove macOS's /private prefix.
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
            let succeeded = project.path.withCString { source in
                resolved.withUnsafeMutableBufferPointer { destination in
                    realpath(source, destination.baseAddress) != nil
                }
            }
            try Task.checkCancellation()
            guard succeeded, let path = resolved.withUnsafeBytes(NativeProcessInventoryParsing.decodeCString),
                  ProcessPath.isCanonicalAbsolute(path), path != "/",
                  (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return ProcessProjectScope(id: project.id, name: project.name, canonicalPath: path)
        }
        return ProcessProjectResolution(scopes: scopes, unavailableCount: candidates.count - scopes.count)
    }
}

enum ProcessInventoryEvent {
    case started(id: UUID, at: Date)
    case finished(id: UUID, status: TaskStatus, count: Int)
}

@MainActor @Observable
final class ProcessInventoryStore {
    private(set) var snapshot: ProcessSnapshot?
    private(set) var isScanning = false
    var selection: Set<ProcessIdentity> = [] {
        didSet { if selection != oldValue { plan = nil } }
    }
    var search = "" { didSet { constrainSelection(); if search != oldValue { plan = nil } } }
    var projectFilterID: UUID? { didSet { constrainSelection(); plan = nil } }
    var portFilter: ProcessPortFilter = .all { didSet { constrainSelection(); if portFilter != oldValue { plan = nil } } }
    private(set) var lastScanStatus: TaskStatus?
    private(set) var unavailableProjectCount = 0
    var plan: StopPlan?
    var errorMessage: String?
    private(set) var projects: [ProcessProjectScope] = []
    @ObservationIgnored var onEvent: ((ProcessInventoryEvent) -> Void)?
    @ObservationIgnored private let provider: any ProcessInventoryProviding
    @ObservationIgnored private let resolver = ProcessProjectResolver()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var activeScanID: UUID?
    @ObservationIgnored private var lastScanStartedAt: Date?
    @ObservationIgnored private let minimumRefreshInterval: TimeInterval

    init(provider: any ProcessInventoryProviding = NativeProcessInventoryProvider(), minimumRefreshInterval: TimeInterval = 2) {
        self.provider = provider
        self.minimumRefreshInterval = max(0, minimumRefreshInterval)
    }

    var rows: [ProcessInventoryRecord] {
        matchingRows.filter { portFilter.includes($0) }
    }

    /// Counts use the same search/project scope as the table, before the port filter.
    func count(for filter: ProcessPortFilter) -> Int {
        matchingRows.filter { filter.includes($0) }.count
    }

    var hasActiveFilters: Bool { !search.isEmpty || projectFilterID != nil || portFilter != .all }

    var retainedSnapshotNotice: String? {
        guard snapshot != nil else { return nil }
        if isScanning { return String(localized: "Refreshing. The previous snapshot remains visible until the scan finishes.") }
        switch lastScanStatus {
        case .cancelled: return String(localized: "Refresh cancelled. Showing the previous snapshot; these rows were not refreshed.")
        case .failed: return String(localized: "Refresh failed. Showing the previous snapshot; these rows were not refreshed.")
        default: return nil
        }
    }

    private var matchingRows: [ProcessInventoryRecord] {
        guard let snapshot else { return [] }
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return snapshot.records.filter { record in
            let association = association(for: record)
            if let projectFilterID, association.projectID != projectFilterID { return false }
            let fields = [record.name, String(record.identity.pid), record.identity.executablePath ?? "",
                          record.workingDirectory ?? "", association.projectName ?? ""]
                + (record.listeningPorts ?? []).flatMap { [String($0.port), $0.address, $0.transport] }
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.identity.pid < $1.identity.pid : comparison == .orderedAscending
        }
    }

    func association(for record: ProcessInventoryRecord) -> ProcessAssociation {
        ProcessClassifier.association(for: record, projects: projects)
    }
    func assessment(for record: ProcessInventoryRecord) -> ProcessAssociationAssessment {
        ProcessClassifier.assessment(for: record, projects: projects)
    }
    func clearFilters() {
        search = ""; projectFilterID = nil; portFilter = .all
    }
    func protectionReasons(for record: ProcessInventoryRecord) -> [String] {
        guard let snapshot else { return [] }
        return ProcessClassifier.protectionReasons(for: record, snapshot: snapshot)
    }
    func associatedCount(for projectID: UUID) -> Int? {
        snapshot.map { $0.records.filter { association(for: $0).projectID == projectID }.count }
    }

    func startScan(projects catalog: [ProjectRecord]) {
        guard !isScanning else { return }
        let now = Date.now
        if let lastScanStartedAt, now.timeIntervalSince(lastScanStartedAt) < minimumRefreshInterval {
            errorMessage = String(localized: "Wait a moment before starting another process scan.")
            return
        }
        lastScanStartedAt = now
        errorMessage = nil; lastScanStatus = nil
        selection = []; plan = nil
        let id = UUID()
        activeScanID = id; isScanning = true
        onEvent?(.started(id: id, at: now))
        scanTask = Task { [weak self, provider, resolver] in
            do {
                let resolution = try await resolver.resolve(catalog)
                try Task.checkCancellation()
                let result = try await provider.scan(options: ProcessScanOptions())
                try Task.checkCancellation()
                guard let self, self.activeScanID == id else { return }
                self.projects = resolution.scopes
                self.unavailableProjectCount = resolution.unavailableCount
                self.snapshot = result
                self.finish(id: id, status: result.isPartial ? .partial : .completed, count: result.records.count)
            } catch is CancellationError {
                guard let self, self.activeScanID == id else { return }
                self.finish(id: id, status: .cancelled, count: 0)
            } catch {
                guard let self, self.activeScanID == id else { return }
                // The native error is deliberately not logged: diagnostics never
                // persist process paths, arguments or arbitrary OS error text.
                self.errorMessage = String(localized: "The process snapshot could not be read. No processes were changed.")
                self.finish(id: id, status: .failed, count: 0)
            }
        }
    }

    func cancel() {
        scanTask?.cancel()
        if let id = activeScanID { finish(id: id, status: .cancelled, count: 0) }
        selection = []; plan = nil
    }

    func resetForModeChange() {
        cancel()
        snapshot = nil; projects = []; unavailableProjectCount = 0
        clearFilters()
        errorMessage = nil; lastScanStartedAt = nil; lastScanStatus = nil
    }

    func openProject(_ project: ProjectRecord, projects: [ProjectRecord]) {
        // Navigation only. No implicit process inspection when a project opens.
        search = ""; portFilter = .all; projectFilterID = project.id; selection = []; plan = nil
    }

    func reviewSelection() {
        constrainSelection()
        guard !isScanning, let snapshot, !selection.isEmpty else { plan = nil; return }
        plan = ProcessStopPlanner.makePlan(snapshot: snapshot, selection: selection, projects: projects)
    }

    private func constrainSelection() {
        selection.formIntersection(Set(rows.map(\.identity)))
    }

    private func finish(id: UUID, status: TaskStatus, count: Int) {
        guard activeScanID == id else { return }
        activeScanID = nil; isScanning = false; scanTask = nil; lastScanStatus = status
        onEvent?(.finished(id: id, status: status, count: count))
    }
}
