import Foundation
import Darwin

/// Stores app metadata only. Never writes to a selected project directory.
/// An unreadable, unsupported or externally changed catalog must be recovered
/// explicitly; saving never uses an empty fallback to replace its original bytes.
final class CatalogPersistence {
    static let maximumBytes = 16 * 1_024 * 1_024

    enum CatalogError: LocalizedError, Equatable {
        case unsupportedFields
        case invalidRecords
        case recoveryRequired
        case changedSinceLoad
        case tooLarge
        case writerBusy
        case unsafeLock

        var errorDescription: String? {
            switch self {
            case .unsupportedFields: String(localized: "The catalog contains unsupported fields. Its original data was preserved.")
            case .invalidRecords: String(localized: "The catalog contains conflicting or invalid projects. Its original data was preserved.")
            case .recoveryRequired: String(localized: "The catalog could not be read. Recover the original file before saving changes.")
            case .changedSinceLoad: String(localized: "The catalog changed outside this window. Changes are temporary; reopen MoeKit to reload the saved catalog.")
            case .tooLarge: String(localized: "The project catalog exceeds the 16 MB limit. Changes were not saved.")
            case .writerBusy: String(localized: "Another MoeKit window is saving the catalog. Changes are temporary; try saving again.")
            case .unsafeLock: String(localized: "The catalog lock is not a private regular file. Changes were not saved.")
            }
        }
    }

    private enum Snapshot {
        case notLoaded
        case loaded(Data?)
        case unreadable
    }

    private let fileURL: URL
    private let beforeAtomicWrite: () throws -> Void
    private var snapshot = Snapshot.notLoaded

    init(directory: URL? = nil,
         beforeAtomicWrite: @escaping () throws -> Void = {}) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MoeKit", isDirectory: true)
        fileURL = root.appendingPathComponent("projects.json")
        self.beforeAtomicWrite = beforeAtomicWrite
    }

    func load() throws -> [ProjectRecord] {
        do {
            let data = try readExistingData()
            let projects = try data.map(Self.decode) ?? []
            snapshot = .loaded(data)
            return projects
        } catch {
            snapshot = .unreadable
            throw error
        }
    }

    func save(_ projects: [ProjectRecord]) throws {
        // A direct save still has to validate any existing catalog first.
        if case .notLoaded = snapshot { _ = try load() }
        guard case let .loaded(previous) = snapshot else { throw CatalogError.recoveryRequired }
        try Self.validate(projects)
        let data = try JSONEncoder().encode(projects)
        guard data.count <= Self.maximumBytes else { throw CatalogError.tooLarge }
        // Cooperating writers use the same permanent sidecar inode. The bounded
        // reread, comparison, replacement and snapshot update are one critical
        // section, including the initially missing-file case.
        try CatalogWriteCoordinator.withExclusiveAccess(at: fileURL.deletingLastPathComponent()) { writer in
            guard try writer.readExistingData() == previous else { throw CatalogError.changedSinceLoad }
            try beforeAtomicWrite()
            try writer.replace(with: data)
            snapshot = .loaded(data)
        }
    }

    private func readExistingData() throws -> Data? {
        do {
            return try BoundedRegularFileReader.read(at: fileURL, maximumBytes: Self.maximumBytes)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            // fileExists conflates missing paths and some access failures. Only a
            // definite ENOENT starts an empty catalog; all other errors propagate.
            return nil
        }
    }

    private static func decode(_ data: Data) throws -> [ProjectRecord] {
        let projects = try JSONDecoder().decode([ProjectRecord].self, from: data)
        // The current format is an unversioned array. Unknown fields must not be
        // decoded and silently discarded on the next save by this older reader.
        let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        let projectKeys: Set<String> = ["id", "name", "path", "kind", "branch", "lastOpened", "isPinned",
                                        "parentID", "demoChangeCount", "demoUnavailable", "gitMetadata"]
        let metadataKeys: Set<String> = ["observedAt", "gitDirectoryPath", "commonDirectoryPath", "isLinkedWorktree", "isLocked"]
        for object in objects {
            guard Set(object.keys).isSubset(of: projectKeys) else { throw CatalogError.unsupportedFields }
            if let metadata = object["gitMetadata"] as? [String: Any], !Set(metadata.keys).isSubset(of: metadataKeys) {
                throw CatalogError.unsupportedFields
            }
        }
        try validate(projects)
        return projects
    }

    private static func validate(_ projects: [ProjectRecord]) throws {
        var ids: Set<UUID> = []
        var paths: Set<String> = []
        for project in projects {
            guard ids.insert(project.id).inserted,
                  project.path.hasPrefix("/"), !project.path.utf8.contains(0),
                  paths.insert(project.url.standardizedFileURL.path).inserted,
                  project.demoChangeCount == nil, !project.demoUnavailable,
                  project.kind != .group else { throw CatalogError.invalidRecords }
        }
        let records = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        for project in projects {
            if let parentID = project.parentID {
                guard parentID != project.id, let parent = records[parentID], parent.parentID == nil else {
                    throw CatalogError.invalidRecords
                }
            }
        }
    }
}
