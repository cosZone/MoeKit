import Foundation
import Observation

/// Resolve only already-added catalog roots. Discovery does not inspect argv,
/// environment, browser profiles or project files to manufacture association.
actor ProcessProjectResolver {
    func resolve(_ projects: [ProjectRecord]) throws -> [ProcessProjectScope] {
        try projects.compactMap { project in
            try Task.checkCancellation()
            guard project.kind != .group, ProcessPath.isCanonicalAbsolute(project.path), project.path != "/" else { return nil }
            let url = project.url.resolvingSymlinksInPath().standardizedFileURL
            guard ProcessPath.isCanonicalAbsolute(url.path), url.path != "/",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return ProcessProjectScope(id: project.id, name: project.name, canonicalPath: url.path)
        }
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
        guard let snapshot else { return [] }
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return snapshot.records.filter { record in
            let association = association(for: record)
            if let projectFilterID, association.projectID != projectFilterID { return false }
            let fields = [record.name, String(record.identity.pid), record.identity.executablePath ?? "",
                          record.workingDirectory ?? "", association.projectName ?? ""]
                + (record.listeningPorts ?? []).map { String($0.port) }
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.identity.pid < $1.identity.pid : comparison == .orderedAscending
        }
    }

    func association(for record: ProcessInventoryRecord) -> ProcessAssociation {
        ProcessClassifier.association(for: record, projects: projects)
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
        errorMessage = nil
        selection = []; plan = nil
        let id = UUID()
        activeScanID = id; isScanning = true
        onEvent?(.started(id: id, at: now))
        scanTask = Task { [weak self, provider, resolver] in
            do {
                let scopes = try await resolver.resolve(catalog)
                try Task.checkCancellation()
                let result = try await provider.scan(options: ProcessScanOptions())
                try Task.checkCancellation()
                guard let self, self.activeScanID == id else { return }
                self.projects = scopes
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
        snapshot = nil; projects = []; search = ""; projectFilterID = nil
        errorMessage = nil; lastScanStartedAt = nil
    }

    func openProject(_ project: ProjectRecord, projects: [ProjectRecord]) {
        // Navigation only. No implicit process inspection when a project opens.
        search = ""; projectFilterID = project.id; selection = []; plan = nil
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
        activeScanID = nil; isScanning = false; scanTask = nil
        onEvent?(.finished(id: id, status: status, count: count))
    }
}
