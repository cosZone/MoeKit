import Foundation
import Darwin

public struct DiscoveredRepository: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case folder
        case gitRepository
        /// A Git file layout, including linked worktrees and submodules.
        case gitWorktree
    }

    public let url: URL
    public let name: String
    public let kind: Kind
    /// A branch name, a detached-HEAD label, or nil when it cannot be read safely.
    public let branch: String?
    public let metadata: GitDiscoveryMetadata?

    public var id: String { url.path }

    public init(url: URL, name: String, kind: Kind, branch: String?, metadata: GitDiscoveryMetadata? = nil) {
        self.url = url
        self.name = name
        self.kind = kind
        self.branch = branch
        self.metadata = metadata
    }
}

public struct ScanOptions: Sendable, Hashable {
    /// The selected root has depth zero. Repositories at this depth are included.
    public let maxDepth: Int
    /// Includes the selected root; excluded and symbolic-link directories do not count.
    public let maxDirectories: Int
    public let includeHidden: Bool
    public let maxEntries: Int

    public init(maxDepth: Int = 4, maxDirectories: Int = 2_000, includeHidden: Bool = false, maxEntries: Int = 100_000) {
        self.maxDepth = maxDepth
        self.maxDirectories = maxDirectories
        self.includeHidden = includeHidden
        self.maxEntries = maxEntries
    }
}

public struct ScanIssue: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case directoryUnreadable
        case metadataUnreadable
        case invalidMetadata
        case metadataTooLarge
        case outsideScope
        case symbolicLinkSkipped
        case depthLimit
        case directoryLimit
        case entryLimit
    }

    public let url: URL
    public let kind: Kind
    public let message: String

    public var id: String { "\(kind.rawValue):\(url.path):\(message)" }

    public init(url: URL, kind: Kind, message: String) {
        self.url = url
        self.kind = kind
        self.message = message
    }
}

public struct RepositoryScanResult: Sendable, Hashable {
    public let items: [DiscoveredRepository]
    public let issues: [ScanIssue]
    public let visitedDirectories: Int
    public let wasLimited: Bool
    public let enumeratedEntries: Int

    public init(
        items: [DiscoveredRepository],
        issues: [ScanIssue],
        visitedDirectories: Int,
        wasLimited: Bool,
        enumeratedEntries: Int = 0
    ) {
        self.items = items
        self.issues = issues
        self.visitedDirectories = visitedDirectories
        self.wasLimited = wasLimited
        self.enumeratedEntries = enumeratedEntries
    }
}

public enum RepositoryScannerError: Error, Sendable, LocalizedError {
    case invalidOptions
    case invalidRoot(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "Choose 1–32 folders. Scan depth must be zero or greater and directory and entry limits must be positive."
        case .invalidRoot(let message):
            return message
        }
    }
}

/// Read-only discovery. This service never invokes Git, a shell, project code, or hooks.
///
/// Discovery is based on `.git` markers, not a claim that a repository is valid or clean.
/// Metadata paths are checked component-by-component and symbolic links are refused.
/// These Foundation checks are best-effort in a concurrently changing filesystem; the
/// caller must retain the selected folder's security scope for the entire operation.
public actor RepositoryScanner {
    public static let maximumMetadataBytes = 16 * 1_024
    /// Also bounds a directory containing a very large number of ordinary files.
    public static let maximumEnumeratedEntries = 100_000

    private static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".build", ".git", "DerivedData", "build", "target", "dist", ".venv", "vendor"
    ]
    private let fileManager = FileManager()

    public init() {}

    /// A scan shares one budget across all roots. Repeated physical roots are ignored;
    /// overlapping roots may discover the same repository, but it is returned once.
    public func scan(roots: [URL], options: ScanOptions = ScanOptions(),
                     progress: (@Sendable (RepositoryScanProgress) async -> Void)? = nil) async throws -> RepositoryScanResult {
        try Task.checkCancellation()
        guard !roots.isEmpty, roots.count <= 32, options.maxDepth >= 0,
              options.maxDirectories > 0, options.maxEntries > 0 else {
            throw RepositoryScannerError.invalidOptions
        }
        var scopes: [Scope] = []
        var issues: [ScanIssue] = []
        for root in roots {
            try Task.checkCancellation()
            do {
                let scope = try makeScope(root)
                if !scopes.contains(where: { $0.root.path == scope.root.path }) { scopes.append(scope) }
            } catch {
                issues.append(ScanIssue(url: root, kind: .directoryUnreadable, message: error.localizedDescription))
            }
        }
        let authorizedRoots = scopes.map(\.root)
        let totalRoots = scopes.count
        var items: [String: DiscoveredRepository] = [:]
        var visited = 0
        var entries = 0
        var limited = false
        for (index, original) in scopes.enumerated() {
            try Task.checkCancellation()
            guard visited < options.maxDirectories, entries < options.maxEntries else {
                limited = true
                issues.append(ScanIssue(url: original.root, kind: visited >= options.maxDirectories ? .directoryLimit : .entryLimit,
                                       message: "The shared scan budget was reached. This selected root was not searched."))
                continue
            }
            let scope = Scope(root: original.root, components: original.components, authorizedRoots: authorizedRoots)
            let beforeDirectories = visited
            let beforeEntries = entries
            let beforeItems = items.count
            let result = try await scanScope(scope, options: ScanOptions(maxDepth: options.maxDepth,
                maxDirectories: options.maxDirectories - visited, includeHidden: options.includeHidden,
                maxEntries: options.maxEntries - entries), progress: { update in
                    await progress?(RepositoryScanProgress(root: update.root, completedRoots: index,
                        totalRoots: totalRoots, visitedDirectories: beforeDirectories + update.visitedDirectories,
                        enumeratedEntries: beforeEntries + update.enumeratedEntries,
                        discoveredRepositories: beforeItems + update.discoveredRepositories))
                })
            for item in result.items { items[item.id] = item }
            visited += result.visitedDirectories
            entries += result.enumeratedEntries
            limited = limited || result.wasLimited
            issues.append(contentsOf: result.issues)
            await progress?(RepositoryScanProgress(root: original.root, completedRoots: index + 1,
                totalRoots: totalRoots, visitedDirectories: visited, enumeratedEntries: entries,
                discoveredRepositories: items.count))
        }
        try Task.checkCancellation()
        return RepositoryScanResult(items: items.values.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending },
            issues: Array(Set(issues)).sorted { $0.id < $1.id }, visitedDirectories: visited,
            wasLimited: limited, enumeratedEntries: entries)
    }

    /// Finds Git repositories only. Use `inspectFolder` to explicitly add a plain folder.
    public func scan(root: URL, options: ScanOptions = ScanOptions()) async throws -> RepositoryScanResult {
        try Task.checkCancellation()
        guard options.maxDepth >= 0, options.maxDirectories > 0, options.maxEntries > 0 else {
            throw RepositoryScannerError.invalidOptions
        }
        return try await scanScope(makeScope(root), options: options, progress: nil)
    }

    private func scanScope(_ scope: Scope, options: ScanOptions,
                           progress: (@Sendable (RepositoryScanProgress) async -> Void)?) async throws -> RepositoryScanResult {
        var issues: [ScanIssue] = []
        var items: [DiscoveredRepository] = []
        var visitedDirectories = 1
        var wasLimited = false

        if let repository = try discover(in: scope.root, scope: scope, issues: &issues) {
            try Task.checkCancellation()
            return RepositoryScanResult(
                items: [repository], issues: issues, visitedDirectories: 1, wasLimited: false
            )
        }

        // The enumerator streams entries; contentsOfDirectory would first allocate every
        // entry in a potentially huge directory. Every yielded directory is checked
        // before the enumerator is allowed to descend into it.
        var enumerationIssues: [ScanIssue] = []
        let enumerationOptions: FileManager.DirectoryEnumerationOptions =
            options.includeHidden ? [] : [.skipsHiddenFiles]
        guard let enumerator = fileManager.enumerator(
            at: scope.root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
            options: enumerationOptions,
            errorHandler: { url, error in
                enumerationIssues.append(ScanIssue(
                    url: url,
                    kind: .directoryUnreadable,
                    message: "Could not enumerate this directory: \(error.localizedDescription)"
                ))
                return true
            }
        ) else {
            try Task.checkCancellation()
            issues.append(contentsOf: enumerationIssues)
            issues.append(ScanIssue(
                url: scope.root, kind: .directoryUnreadable,
                message: "Could not start enumerating the selected directory."
            ))
            return RepositoryScanResult(
                items: [], issues: issues, visitedDirectories: 1, wasLimited: false
            )
        }

        var enumeratedEntries = 0
        var reportedDepthLimit = false
        while let candidate = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard enumeratedEntries < options.maxEntries else {
                wasLimited = true
                issues.append(ScanIssue(
                    url: scope.root, kind: .entryLimit,
                    message: "Stopped after examining \(options.maxEntries) directory entries. Results are partial."
                ))
                break
            }
            enumeratedEntries += 1
            if enumeratedEntries == 1 || enumeratedEntries.isMultiple(of: 64) {
                await progress?(RepositoryScanProgress(root: scope.root, completedRoots: 0, totalRoots: 1,
                    visitedDirectories: visitedDirectories, enumeratedEntries: enumeratedEntries,
                    discoveredRepositories: items.count))
            }

            // Enumerator URLs already have explicit path components. Foundation's
            // standardization may resolve symlinks while simplifying `..`; do not
            // invoke it on any discovered or metadata-controlled path.
            let directory = candidate
            guard scope.contains(directory) else {
                enumerator.skipDescendants()
                issues.append(ScanIssue(
                    url: directory, kind: .outsideScope,
                    message: "Skipped a path outside the selected folder."
                ))
                continue
            }

            do {
                // Read fresh attributes rather than trusting the enumerator's cache.
                let attributes = try fileManager.attributesOfItem(atPath: directory.path)
                let type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    enumerator.skipDescendants()
                    // A skipped symbolic link is intentional, not an incomplete scan.
                    continue
                }
                guard type == .typeDirectory else { continue }
                if Self.skippedDirectoryNames.contains(directory.lastPathComponent)
                    || (!options.includeHidden && directory.lastPathComponent.hasPrefix(".")) {
                    enumerator.skipDescendants()
                    continue
                }

                let depth = directory.pathComponents.count - scope.components.count
                if depth > options.maxDepth {
                    enumerator.skipDescendants()
                    wasLimited = true
                    if !reportedDepthLimit {
                        issues.append(ScanIssue(
                            url: scope.root, kind: .depthLimit,
                            message: "Subfolders deeper than \(options.maxDepth) levels were not searched. Results are partial."
                        ))
                        reportedDepthLimit = true
                    }
                    continue
                }
                guard visitedDirectories < options.maxDirectories else {
                    wasLimited = true
                    issues.append(ScanIssue(
                        url: scope.root, kind: .directoryLimit,
                        message: "Stopped after visiting \(options.maxDirectories) directories. Results are partial."
                    ))
                    break
                }

                try requireSafePath(directory, scope: scope)
                visitedDirectories += 1
                if let repository = try discover(in: directory, scope: scope, issues: &issues) {
                    items.append(repository)
                    // Nested repositories are intentionally left to an explicit scan.
                    enumerator.skipDescendants()
                }
            } catch let failure as MetadataFailure {
                enumerator.skipDescendants()
                issues.append(failure.issue)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                enumerator.skipDescendants()
                issues.append(ScanIssue(
                    url: directory, kind: .directoryUnreadable,
                    message: "Could not inspect this directory: \(error.localizedDescription)"
                ))
            }
        }
        try Task.checkCancellation()
        issues.append(contentsOf: enumerationIssues)
        items.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        return RepositoryScanResult(
            items: items, issues: issues,
            visitedDirectories: visitedDirectories, wasLimited: wasLimited, enumeratedEntries: enumeratedEntries
        )
    }

    /// Inspects exactly the selected folder, preserving metadata warnings in the result.
    public func inspectFolder(_ url: URL) async throws -> RepositoryScanResult {
        try Task.checkCancellation()
        let scope = try makeScope(url)
        var issues: [ScanIssue] = []
        let item = try discover(in: scope.root, scope: scope, issues: &issues)
            ?? DiscoveredRepository(
                url: scope.root, name: scope.root.lastPathComponent,
                kind: .folder, branch: nil
            )
        try Task.checkCancellation()
        return RepositoryScanResult(
            items: [item], issues: issues, visitedDirectories: 1, wasLimited: false
        )
    }

    private struct Scope {
        let root: URL
        let components: [String]
        var authorizedRoots: [URL] = []
        var allowedRoots: [URL] { authorizedRoots.isEmpty ? [root] : authorizedRoots }

        func metadataRoot(for url: URL) -> URL? {
            guard url.isFileURL, !url.pathComponents.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
            return allowedRoots.filter { url.pathComponents.starts(with: $0.pathComponents) }
                .max { $0.pathComponents.count < $1.pathComponents.count }
        }

        func isAuthorizedAncestor(_ url: URL) -> Bool {
            allowedRoots.contains { $0.pathComponents.starts(with: url.pathComponents) }
        }

        func contains(_ url: URL) -> Bool {
            let candidate = url.pathComponents
            return url.isFileURL
                && !candidate.contains(where: { $0 == "." || $0 == ".." })
                && candidate.starts(with: components)
        }
    }

    private struct MetadataFailure: Error {
        let issue: ScanIssue
    }

    private func makeScope(_ input: URL) throws -> Scope {
        guard input.isFileURL, input.host == nil || input.host == "" || input.host == "localhost" else {
            throw RepositoryScannerError.invalidRoot("Choose a local folder to scan.")
        }
        let selected = input
        do {
            let attributes = try fileManager.attributesOfItem(atPath: selected.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw RepositoryScannerError.invalidRoot("The selected path must be a folder, not a file or symbolic link.")
            }
            // Canonicalize only this explicitly selected root. Foundation URL path
            // normalization can shorten /private/var back to /var on macOS, while
            // directory enumeration returns /private/var, breaking exact containment.
            // realpath gives one physical spelling without that alias rewrite.
            let root = try selected.withUnsafeFileSystemRepresentation { path -> URL in
                guard let path else {
                    throw RepositoryScannerError.invalidRoot("The selected folder has no filesystem path.")
                }
                guard let resolved = Darwin.realpath(path, nil) else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                defer { Darwin.free(resolved) }
                return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            }
            return Scope(root: root, components: root.pathComponents)
        } catch let error as RepositoryScannerError {
            throw error
        } catch {
            throw RepositoryScannerError.invalidRoot("Could not open the selected folder: \(error.localizedDescription)")
        }
    }

    private func discover(
        in directory: URL,
        scope: Scope,
        issues: inout [ScanIssue]
    ) throws -> DiscoveredRepository? {
        try Task.checkCancellation()
        let marker = directory.appendingPathComponent(".git", isDirectory: false)
        let attributes: [FileAttributeKey: Any]
        do {
            try requireSafePath(directory, scope: scope)
            attributes = try fileManager.attributesOfItem(atPath: marker.path)
        } catch let failure as MetadataFailure {
            issues.append(failure.issue)
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isMissingFile(error) { return nil }
            issues.append(ScanIssue(
                url: marker, kind: .metadataUnreadable,
                message: "Could not inspect Git metadata: \(error.localizedDescription)"
            ))
            return nil
        }

        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            issues.append(ScanIssue(
                url: marker, kind: .symbolicLinkSkipped,
                message: "The .git marker is a symbolic link and was not followed."
            ))
            return nil
        }
        guard type == .typeDirectory || type == .typeRegular else {
            issues.append(ScanIssue(
                url: marker, kind: .invalidMetadata,
                message: "The .git marker is not a regular file or directory."
            ))
            return nil
        }

        let kind: DiscoveredRepository.Kind = type == .typeDirectory ? .gitRepository : .gitWorktree
        var branch: String?
        var metadata: GitDiscoveryMetadata?
        do {
            let gitDirectory: URL
            if kind == .gitRepository {
                gitDirectory = marker
            } else {
                let pointer = try boundedUTF8(at: marker, scope: scope)
                gitDirectory = try self.gitDirectory(from: pointer, repository: directory, marker: marker, scope: scope)
            }
            try requireSafePath(gitDirectory, scope: scope)
            let gitAttributes = try fileManager.attributesOfItem(atPath: gitDirectory.path)
            guard gitAttributes[.type] as? FileAttributeType == .typeDirectory else {
                throw metadataFailure(gitDirectory, .invalidMetadata, "The Git metadata target is not a directory.")
            }
            let head = gitDirectory.appendingPathComponent("HEAD", isDirectory: false)
            let contents = try boundedUTF8(at: head, scope: scope)
            branch = try branchLabel(from: contents, head: head)
            var commonDirectory = gitDirectory
            var isLinkedWorktree = false
            if kind == .gitWorktree {
                let commonFile = gitDirectory.appendingPathComponent("commondir")
                do {
                    let common = try boundedUTF8(at: commonFile, scope: scope)
                    commonDirectory = try metadataPath(common, relativeTo: gitDirectory, marker: commonFile, scope: scope)
                    guard commonDirectory.path != gitDirectory.path else {
                        throw metadataFailure(commonFile, .invalidMetadata, "A worktree cannot use itself as its common Git directory.")
                    }
                    let backlinkFile = gitDirectory.appendingPathComponent("gitdir")
                    let backlink = try boundedUTF8(at: backlinkFile, scope: scope)
                    let linkedMarker = try metadataPath(backlink, relativeTo: gitDirectory, marker: backlinkFile,
                                                        scope: scope, isDirectory: false)
                    guard linkedMarker.path == marker.path else {
                        throw metadataFailure(backlinkFile, .invalidMetadata, "The worktree backlink does not match this working directory. Relationship is unknown.")
                    }
                    isLinkedWorktree = true
                } catch {
                    // A plain gitfile (for example a submodule) has no commondir.
                    // It must not be labelled a linked worktree on that evidence alone.
                    if !isMissingFile(error) { throw error }
                    // Only a missing commondir is a plain gitfile. A present commondir
                    // with a missing backlink or target is incomplete worktree evidence.
                    if fileManager.fileExists(atPath: commonFile.path) { throw error }
                    commonDirectory = gitDirectory
                }
            }
            var isLocked = false
            if isLinkedWorktree {
                let lockFile = gitDirectory.appendingPathComponent("locked")
                do {
                    _ = try boundedUTF8(at: lockFile, scope: scope)
                    isLocked = true
                } catch {
                    if !isMissingFile(error) { throw error }
                }
            }
            metadata = GitDiscoveryMetadata(observedAt: .now, gitDirectoryPath: gitDirectory.path,
                commonDirectoryPath: commonDirectory.path, isLinkedWorktree: isLinkedWorktree, isLocked: isLocked)
        } catch let failure as MetadataFailure {
            issues.append(failure.issue)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            issues.append(ScanIssue(
                url: marker, kind: .metadataUnreadable,
                message: "Some Git metadata could not be read; relationship details may be unknown: \(error.localizedDescription)"
            ))
        }
        return DiscoveredRepository(
            url: directory, name: directory.lastPathComponent, kind: kind, branch: branch, metadata: metadata
        )
    }

    /// Reject outside paths before accessing any of their metadata. Never resolve an
    /// untrusted pointer's symlinks; inspect each component inside the scope instead.
    private func requireSafePath(_ url: URL, scope: Scope) throws {
        try Task.checkCancellation()
        guard let metadataRoot = scope.metadataRoot(for: url) else {
            throw metadataFailure(url, .outsideScope, "Git metadata is outside the selected folder. Branch is unknown.")
        }
        var cursor = metadataRoot
        let relative = url.pathComponents.dropFirst(metadataRoot.pathComponents.count)
        let rootAttributes = try fileManager.attributesOfItem(atPath: cursor.path)
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw metadataFailure(cursor, .symbolicLinkSkipped, "The selected folder changed during discovery; this path was skipped.")
        }
        for component in relative {
            try Task.checkCancellation()
            cursor.appendPathComponent(component)
            let attributes = try fileManager.attributesOfItem(atPath: cursor.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw metadataFailure(cursor, .symbolicLinkSkipped, "A symbolic link in the metadata path was not followed. Branch is unknown.")
            }
        }
    }

    private func boundedUTF8(at url: URL, scope: Scope) throws -> String {
        try requireSafePath(url, scope: scope)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw metadataFailure(url, .invalidMetadata, "Git metadata must be a regular UTF-8 file.")
        }
        guard let size = attributes[.size] as? NSNumber,
              size.uint64Value <= UInt64(Self.maximumMetadataBytes) else {
            throw metadataFailure(url, .metadataTooLarge, "Git metadata exceeds the 16 KiB safety limit. Branch is unknown.")
        }
        let data: Data
        do {
            data = try BoundedRegularFileReader.read(at: url, maximumBytes: Self.maximumMetadataBytes) {
                try requireSafePath(url, scope: scope)
            }
        } catch let error as BoundedRegularFileReader.ReadError {
            switch error {
            case .tooLarge:
                throw metadataFailure(url, .metadataTooLarge, "Git metadata exceeds the 16 KiB safety limit. Branch is unknown.")
            case .symbolicLink:
                throw metadataFailure(url, .symbolicLinkSkipped, "Git metadata became a symbolic link and was not followed. Branch is unknown.")
            case .notRegularFile:
                throw metadataFailure(url, .invalidMetadata, "Git metadata must be a regular UTF-8 file.")
            case .changedDuringRead, .invalidPath, .invalidLimit:
                throw metadataFailure(url, .metadataUnreadable, "Git metadata changed or could not be read safely. Branch is unknown.")
            }
        }
        try requireSafePath(url, scope: scope)
        guard let string = String(data: data, encoding: .utf8) else {
            throw metadataFailure(url, .invalidMetadata, "Git metadata is not valid UTF-8. Branch is unknown.")
        }
        return string
    }

    private func gitDirectory(
        from contents: String,
        repository: URL,
        marker: URL,
        scope: Scope
    ) throws -> URL {
        let line = contents.trimmingCharacters(in: .newlines)
        guard line.hasPrefix("gitdir: ") else {
            throw metadataFailure(marker, .invalidMetadata, "The .git file does not contain a valid Git directory pointer.")
        }
        return try metadataPath(String(line.dropFirst("gitdir: ".count)), relativeTo: repository, marker: marker, scope: scope)
    }

    private func metadataPath(_ contents: String, relativeTo base: URL, marker: URL,
                              scope: Scope, isDirectory: Bool = true) throws -> URL {
        let path = contents.trimmingCharacters(in: .newlines)
        guard !path.isEmpty, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw metadataFailure(marker, .invalidMetadata, "The Git metadata pointer is empty or contains control characters.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var cursor: URL
        let remaining: ArraySlice<String>
        if path.hasPrefix("/") {
            guard let root = scope.allowedRoots.filter({ components.starts(with: $0.pathComponents.filter { $0 != "/" }) })
                .min(by: { $0.pathComponents.count < $1.pathComponents.count }) else {
                throw metadataFailure(marker, .outsideScope, "Git metadata is outside the selected folders. Relationship is unknown.")
            }
            cursor = root
            remaining = components.dropFirst(root.pathComponents.filter { $0 != "/" }.count)
        } else {
            cursor = base
            remaining = components[...]
        }
        try requireSafePath(cursor, scope: scope)
        for (offset, component) in remaining.enumerated() {
            try Task.checkCancellation()
            if component == "." { continue }
            if component == ".." { cursor.deleteLastPathComponent() }
            else { cursor.appendPathComponent(component) }
            if scope.metadataRoot(for: cursor) == nil {
                // Walking between explicitly selected sibling roots may pass through
                // their parent. No attributes or content are read from that parent.
                guard scope.isAuthorizedAncestor(cursor) else {
                    throw metadataFailure(marker, .outsideScope, "Git metadata leaves the selected folders. Relationship is unknown.")
                }
                continue
            }
            try requireSafePath(cursor, scope: scope)
            let attributes = try fileManager.attributesOfItem(atPath: cursor.path)
            let expected: FileAttributeType = (!isDirectory && offset == remaining.count - 1) ? .typeRegular : .typeDirectory
            guard attributes[.type] as? FileAttributeType == expected else {
                throw metadataFailure(cursor, .invalidMetadata, "The Git metadata path contains an unexpected file type.")
            }
        }
        try requireSafePath(cursor, scope: scope)
        return cursor
    }

    private func branchLabel(from contents: String, head: URL) throws -> String {
        let line = contents.trimmingCharacters(in: .newlines)
        let prefix = "ref: refs/heads/"
        if line.hasPrefix(prefix) {
            let branch = String(line.dropFirst(prefix.count))
            let forbidden = CharacterSet.whitespacesAndNewlines
                .union(.controlCharacters).union(CharacterSet(charactersIn: "~^:?*[\\"))
            let components = branch.split(separator: "/", omittingEmptySubsequences: false)
            guard !branch.isEmpty,
                  !branch.contains(".."), !branch.contains("@{"),
                  !branch.unicodeScalars.contains(where: forbidden.contains),
                  !components.contains(where: { $0.isEmpty || $0.hasPrefix(".") || $0.hasSuffix(".") || $0.hasSuffix(".lock") }) else {
                throw metadataFailure(head, .invalidMetadata, "HEAD contains an invalid branch reference. Branch is unknown.")
            }
            // HEAD references are display data only; no ref or config file is opened.
            return branch
        }
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if (line.count == 40 || line.count == 64), line.unicodeScalars.allSatisfy(hex.contains) {
            return "Detached @ \(line.prefix(7))"
        }
        throw metadataFailure(head, .invalidMetadata, "HEAD is empty or has an unsupported format. Branch is unknown.")
    }

    private func metadataFailure(_ url: URL, _ kind: ScanIssue.Kind, _ message: String) -> MetadataFailure {
        MetadataFailure(issue: ScanIssue(url: url, kind: kind, message: message))
    }

    private func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
}
