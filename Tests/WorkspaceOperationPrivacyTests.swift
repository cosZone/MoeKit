import Foundation
import Testing
@testable import MoeKit

@Suite("Workspace operation ownership and Demo privacy", .timeLimit(.minutes(1))) @MainActor
struct WorkspaceOperationPrivacyTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-operation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func report(_ path: String) throws -> MoleAnalyzeReport {
        let data = try JSONSerialization.data(withJSONObject: ["path": path, "overview": false, "entries": [], "total_size": 0])
        return try JSONDecoder().decode(MoleAnalyzeReport.self, from: data)
    }

    private func result(_ root: URL) -> RepositoryScanResult {
        RepositoryScanResult(items: [DiscoveredRepository(url: root, name: "Synthetic", kind: .folder, branch: nil)],
                             issues: [], visitedDirectories: 1, wasLimited: false)
    }

    private func progress(_ root: URL) -> RepositoryScanProgress {
        RepositoryScanProgress(root: root, completedRoots: 0, totalRoots: 1,
                               visitedDirectories: 1, enumeratedEntries: 1, discoveredRepositories: 0)
    }

    private func privateError(_ root: URL) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: "private-filename.json in \(root.path)", NSFilePathErrorKey: root.path])
    }

    @Test("Initialization, Demo navigation and blocked Demo imports never start reads or write a catalog")
    func explicitWorkOnly() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = ControlledReportImporter()
        let scanner = ControlledRepositoryScanner()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root),
                                   scanner: scanner, reportImporter: importer)
        store.openGettingStartedGoal(.demo)
        #expect(store.startMoleReportImport(root) == nil)
        #expect(store.startDiscovery(roots: [root], scanChildren: true) == nil)
        store.openGettingStartedGoal(.projects)
        #expect(await importer.operation.count == 0)
        #expect(await scanner.operation.count == 0)
        #expect(store.projects.isEmpty && store.tasks.isEmpty)
        #expect(store.importedReport == nil && store.errorMessage == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Mode transitions remove existing operation errors, without reviving them on return")
    func existingErrorBoundary() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root))
        for _ in 0..<3 {
            store.errorMessage = privateError(root).localizedDescription
            store.isDemoEnabled = true
            #expect(store.errorMessage == nil)
            store.isDemoEnabled = false
            #expect(store.errorMessage == nil)
        }
    }

    @Test("Repeated imports are coalesced and setting the same mode does not cancel work")
    func repeatedImport() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = ControlledReportImporter()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root), reportImporter: importer)
        let task = try #require(store.startMoleReportImport(root))
        await importer.operation.waitUntilStarted(root)
        #expect(store.startMoleReportImport(root.appendingPathComponent("ignored")) == nil)
        store.isDemoEnabled = false
        #expect(store.isImporting)
        #expect(!store.showGettingStarted())
        let expected = try report("/synthetic/current")
        await importer.operation.complete(root, with: expected)
        await task.value
        #expect(await importer.operation.count == 1)
        #expect(store.importedReport == expected && store.importedAt != nil)
        #expect(!store.isImporting && store.errorMessage == nil)
    }

    @Test("Immediate import cancellation does not invoke the importer")
    func cancelBeforeImportStarts() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = ControlledReportImporter()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root), reportImporter: importer)
        let task = try #require(store.startMoleReportImport(root))
        store.cancelMoleReportImport()
        await task.value
        #expect(await importer.operation.count == 0)
        #expect(!store.isImporting && store.errorMessage == nil && store.importedReport == nil)
    }

    @Test("Cancelling returned handles before execution releases ownership and records cancellation")
    func immediateHandleCancellation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = ControlledReportImporter()
        let scanner = ControlledRepositoryScanner()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root),
                                   scanner: scanner, reportImporter: importer)
        let imported = try #require(store.startMoleReportImport(root))
        let discovered = try #require(store.startDiscovery(roots: [root], scanChildren: true))
        imported.cancel(); discovered.cancel()
        await imported.value; await discovered.value
        #expect(!store.isImporting && !store.isScanning)
        #expect(await importer.operation.count == 0)
        #expect(await scanner.operation.count == 0)
        #expect(store.tasks.first?.status == .cancelled && store.errorMessage == nil)
    }

    @Test("Cancelled imports preserve the previous report and time, even on late arbitrary failures")
    func cancelledImportPreservesReport() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = ControlledReportImporter()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root), reportImporter: importer)
        let previous = try report("/synthetic/previous")
        let time = Date(timeIntervalSince1970: 123)
        store.importedReport = previous; store.importedAt = time
        let task = try #require(store.startMoleReportImport(root))
        await importer.operation.waitUntilStarted(root)
        store.cancelMoleReportImport()
        #expect(!store.isImporting)
        await importer.operation.fail(root, with: privateError(root))
        await task.value
        #expect(store.errorMessage == nil)
        #expect(store.importedReport == previous && store.importedAt == time)
    }

    @Test("Late import success and failure cannot cross repeated mode boundaries", arguments: [false, true])
    func importModeBoundary(fails: Bool) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = ControlledReportImporter()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root), reportImporter: importer)
        let previous = try report("/synthetic/previous")
        store.importedReport = previous
        for endsInDemo in [true, false] {
            store.isDemoEnabled = false
            let task = try #require(store.startMoleReportImport(root))
            await importer.operation.waitUntilStarted(root)
            for _ in 0..<3 { store.isDemoEnabled = true; store.isDemoEnabled = false }
            store.isDemoEnabled = endsInDemo
            if fails { await importer.operation.fail(root, with: privateError(root)) }
            else { await importer.operation.complete(root, with: try report("/synthetic/obsolete")) }
            await task.value
            #expect(store.importedReport == previous && store.importedAt == nil)
            #expect(!store.isImporting && store.errorMessage == nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("An older import cannot clear a new import's ownership or publish its result or error", arguments: [false, true])
    func importReentry(fails: Bool) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = ControlledReportImporter()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root), reportImporter: importer)
        let oldURL = root.appendingPathComponent("old"), newURL = root.appendingPathComponent("new")
        let old = try #require(store.startMoleReportImport(oldURL))
        await importer.operation.waitUntilStarted(oldURL)
        store.isDemoEnabled = true; store.isDemoEnabled = false
        let current = try #require(store.startMoleReportImport(newURL))
        await importer.operation.waitUntilStarted(newURL)
        if fails { await importer.operation.fail(oldURL, with: privateError(root)) }
        else { await importer.operation.complete(oldURL, with: try report("/synthetic/obsolete")) }
        await old.value
        #expect(store.isImporting && store.importedReport == nil && store.errorMessage == nil)
        #expect(store.startMoleReportImport(oldURL) == nil)
        let expected = try report("/synthetic/new")
        await importer.operation.complete(newURL, with: expected)
        await current.value
        #expect(!store.isImporting && store.importedReport == expected)
    }

    @Test("A cancelled operation that finishes last cannot overwrite a completed newer import")
    func importFinishesLast() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = ControlledReportImporter()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root), reportImporter: importer)
        let old = try #require(store.startMoleReportImport(root))
        await importer.operation.waitUntilStarted(root)
        store.cancelMoleReportImport()
        let nextURL = root.appendingPathComponent("next")
        let next = try #require(store.startMoleReportImport(nextURL))
        await importer.operation.waitUntilStarted(nextURL)
        let expected = try report("/synthetic/new")
        await importer.operation.complete(nextURL, with: expected)
        await next.value
        let time = store.importedAt
        await importer.operation.complete(root, with: try report("/synthetic/old"))
        await old.value
        #expect(store.importedReport == expected && store.importedAt == time)
        #expect(!store.isImporting && store.errorMessage == nil)
    }

    @Test("Current import errors use actionable fixed text, never filename or decoder context")
    func importErrorPrivacy() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = ControlledReportImporter()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root), reportImporter: importer)
        let errors: [any Error] = [privateError(root),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: root.path, underlyingError: privateError(root))),
            MoleReportImporter.ImportError.notRegularFile, MoleReportImporter.ImportError.tooLarge,
            MoleReportImporter.ImportError.changedDuringRead]
        let expected = [String(localized: "The report could not be read. Check access to the selected file and try again."),
                        String(localized: "The selected file is not a supported Mole JSON report. Export a new analyze --json report and try again."),
                        MoleReportImporter.ImportError.notRegularFile.localizedDescription,
                        MoleReportImporter.ImportError.tooLarge.localizedDescription,
                        MoleReportImporter.ImportError.changedDuringRead.localizedDescription]
        for (error, message) in zip(errors, expected) {
            let task = try #require(store.startMoleReportImport(root))
            await importer.operation.waitUntilStarted(root)
            await importer.operation.fail(root, with: error)
            await task.value
            #expect(store.errorMessage == message)
            #expect(!message.contains(root.path) && !message.contains("private-filename"))
            store.errorMessage = nil
        }
    }

    @Test("Stale discovery progress, success, errors and cleanup cannot affect newer work", arguments: [false, true])
    func discoveryReentry(fails: Bool) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = ControlledRepositoryScanner()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root), scanner: scanner)
        let oldURL = root.appendingPathComponent("old"), newURL = root.appendingPathComponent("new")
        let old = try #require(store.startDiscovery(roots: [oldURL], scanChildren: true))
        await scanner.operation.waitUntilStarted(oldURL)
        await scanner.emit(progress(oldURL))
        #expect(store.scanProgress?.root == oldURL)
        let oldID = try #require(store.tasks.first?.id)
        store.isDemoEnabled = true; store.isDemoEnabled = false
        #expect(!store.isScanning && store.scanProgress == nil)
        #expect(store.tasks.first?.status == .cancelled)
        let next = try #require(store.startDiscovery(roots: [newURL], scanChildren: true))
        await scanner.operation.waitUntilStarted(newURL)
        await scanner.emit(progress(newURL))
        await scanner.emit(progress(oldURL)) // A fresh callback task is not itself cancelled.
        #expect(store.scanProgress?.root == newURL)
        if fails { await scanner.operation.fail(oldURL, with: privateError(root)) }
        else { await scanner.operation.complete(oldURL, with: result(oldURL)) }
        await old.value
        #expect(store.isScanning && store.scanProgress?.root == newURL)
        #expect(store.pendingDiscovery == nil && store.errorMessage == nil)
        #expect(store.tasks.first(where: { $0.id == oldID })?.status == .cancelled)
        #expect(store.tasks.first?.status == .running)
        await scanner.operation.complete(newURL, with: result(newURL))
        await next.value
        #expect(!store.isScanning && store.scanProgress == nil)
        #expect(store.pendingDiscovery?.items.first?.url == newURL)
        #expect(store.tasks.first?.status == .completed && store.projects.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Late direct-folder results cannot save a catalog while in Demo")
    func directFolderModeBoundary() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = ControlledRepositoryScanner()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root), scanner: scanner)
        let selected = root.appendingPathComponent("synthetic-not-created")
        let task = try #require(store.startDiscovery(roots: [selected], scanChildren: false))
        await scanner.operation.waitUntilStarted(selected)
        store.isDemoEnabled = true
        await scanner.operation.complete(selected, with: result(selected))
        await task.value
        #expect(store.projects.isEmpty && store.pendingDiscovery == nil && store.errorMessage == nil)
        #expect(store.tasks.first?.status == .cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Discovery cancellation and current failure have distinct sanitized terminal states")
    func discoveryFailureAndCancel() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = ControlledRepositoryScanner()
        let store = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: root), scanner: scanner)
        for cancel in [true, false] {
            let task = try #require(store.startDiscovery(roots: [root], scanChildren: true))
            await scanner.operation.waitUntilStarted(root)
            if cancel { store.cancelScan() }
            await scanner.operation.fail(root, with: privateError(root))
            await task.value
            #expect(!store.isScanning && store.pendingDiscovery == nil)
            #expect(store.tasks.first?.status == (cancel ? .cancelled : .failed))
            // Evaluate the optional/coalescing expression before the assertion
            // macro so Swift Testing does not rewrite it as an optional call.
            let summary = try #require(store.tasks.first?.summary)
            #expect(summary.contains(root.path) == false)
            #expect(summary == (cancel ? String(localized: "Discovery cancelled. No files were changed.")
                : String(localized: "The selected folders could not be read. Choose accessible folders and try again. No files were changed.")))
            if cancel { #expect(store.errorMessage == nil) }
            else {
                #expect(store.errorMessage == String(localized: "The selected folders could not be read. Choose accessible folders and try again. No files were changed."))
            }
        }
    }

    @Test("Unreadable catalog warnings stay out of Demo and return as fixed recovery guidance")
    func catalogWarningBoundary() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects.json")
        let bytes = Data("{broken private-filename".utf8)
        try bytes.write(to: file)
        let store = WorkspaceStore(isDemoEnabled: true, persistence: CatalogPersistence(directory: root))
        #expect(store.errorMessage == nil && !store.showAutomaticGettingStarted())
        store.isDemoEnabled = false
        let warning = String(localized: "The project catalog could not be read. Existing data was not replaced.")
        #expect(store.errorMessage == warning && !store.showAutomaticGettingStarted())
        store.errorMessage = privateError(root).localizedDescription
        store.isDemoEnabled = true
        #expect(store.errorMessage == nil)
        store.isDemoEnabled = false
        #expect(store.errorMessage == warning)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("Save failures retain sanitized recovery guidance across modes until a successful save")
    func saveWarningRecovery() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(name: "Synthetic", path: root.appendingPathComponent("project").path, kind: .folder)
        try CatalogPersistence(directory: root).save([project])
        var shouldFail = true
        let failure = privateError(root)
        let persistence = CatalogPersistence(directory: root) { data, file in
            if shouldFail { throw failure }
            try data.write(to: file, options: .atomic)
        }
        let store = WorkspaceStore(isDemoEnabled: false, persistence: persistence)
        store.togglePin(project.id)
        let warning = String(localized: "Changes could not be saved. They are temporary; check available disk space and folder access, then try again.")
        #expect(store.errorMessage == warning)
        store.isDemoEnabled = true
        #expect(store.errorMessage == nil)
        store.isDemoEnabled = false
        #expect(store.errorMessage == warning)
        shouldFail = false
        store.togglePin(project.id)
        #expect(store.errorMessage == nil)
        store.isDemoEnabled = true; store.isDemoEnabled = false
        #expect(store.errorMessage == nil)
    }
}

/// Deliberately ignores cancellation. Completion is explicitly awaited by the
/// tests using the coordinator's returned Task; no arbitrary scheduler sleeps.
private actor ControlledWorkspaceOperation<Value: Sendable> {
    private var pending: [URL: CheckedContinuation<Value, any Error>] = [:]
    private var started: [URL: CheckedContinuation<Void, Never>] = [:]
    private(set) var count = 0

    func run(_ url: URL) async throws -> Value {
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[url] = continuation
            started.removeValue(forKey: url)?.resume()
        }
    }
    func waitUntilStarted(_ url: URL) async {
        if pending[url] != nil { return }
        await withCheckedContinuation { started[url] = $0 }
    }
    func complete(_ url: URL, with value: Value) {
        pending.removeValue(forKey: url)?.resume(returning: value)
    }
    func fail(_ url: URL, with error: any Error) {
        pending.removeValue(forKey: url)?.resume(throwing: error)
    }
}

private actor ControlledReportImporter: WorkspaceReportImporting {
    let operation = ControlledWorkspaceOperation<MoleAnalyzeReport>()
    func load(_ url: URL) async throws -> MoleAnalyzeReport { try await operation.run(url) }
}

private actor ControlledRepositoryScanner: WorkspaceRepositoryScanning {
    let operation = ControlledWorkspaceOperation<RepositoryScanResult>()
    private var callbacks: [URL: @Sendable (RepositoryScanProgress) async -> Void] = [:]
    func scan(roots: [URL], options: ScanOptions,
              progress: (@Sendable (RepositoryScanProgress) async -> Void)?) async throws -> RepositoryScanResult {
        if let progress { callbacks[roots[0]] = progress }
        return try await operation.run(roots[0])
    }
    func inspectFolder(_ url: URL) async throws -> RepositoryScanResult { try await operation.run(url) }
    func emit(_ progress: RepositoryScanProgress) async { await callbacks[progress.root]?(progress) }
}
