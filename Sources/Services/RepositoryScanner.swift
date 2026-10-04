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
        case resourceLimit
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
/// Enumeration and metadata reads use pinned directory descriptors, never repeated
/// absolute-path opens. Identity checks detect observable replacement, not an atomic
/// filesystem snapshot. The caller retains security scope for the whole operation.
public actor RepositoryScanner {
    public static let maximumMetadataBytes = 16 * 1_024
    /// Also bounds a directory containing a very large number of ordinary files.
    public static let maximumEnumeratedEntries = 100_000

    private static let skippedDirectoryNames: Set<String> = [
        "node_modules", ".build", ".git", "DerivedData", "build", "target", "dist", ".venv", "vendor"
    ]
    private let beforeMetadataOpen: (@Sendable (URL) throws -> Void)?

    public init() { beforeMetadataOpen = nil }

    /// Deterministic synthetic race injection; never used by the application.
    init(beforeMetadataOpen: @escaping @Sendable (URL) throws -> Void) {
        self.beforeMetadataOpen = beforeMetadataOpen
    }

    /// A scan shares one budget across all roots. Repeated physical roots are ignored;
    /// overlapping roots may discover the same repository, but it is returned once.
    public func scan(roots: [URL], options: ScanOptions = ScanOptions(),
                     progress: (@Sendable (RepositoryScanProgress) async -> Void)? = nil) async throws -> RepositoryScanResult {
        try Task.checkCancellation()
        guard !roots.isEmpty, roots.count <= 32, options.maxDepth >= 0,
              options.maxDirectories > 0, options.maxEntries > 0 else {
            throw RepositoryScannerError.invalidOptions
        }
        let descriptorBudget = AnchoredDirectory.Budget()
        var scopes: [Scope] = []
        var issues: [ScanIssue] = []
        for root in roots {
            try Task.checkCancellation()
            do {
                let scope = try makeScope(root, budget: descriptorBudget)
                if !scopes.contains(where: { $0.root.path == scope.root.path }) { scopes.append(scope) }
            } catch let error as AnchoredDirectory.AccessError where error == .descriptorLimit {
                issues.append(ScanIssue(url: root, kind: .resourceLimit,
                    message: "The shared directory-handle limit was reached. This selected root was not searched."))
            } catch {
                issues.append(ScanIssue(url: root, kind: .directoryUnreadable, message: error.localizedDescription))
            }
        }
        let authorizedRoots = scopes.map(\.anchor)
        let totalRoots = scopes.count
        var items: [String: DiscoveredRepository] = [:]
        var visited = 0
        var entries = 0
        var limited = issues.contains { $0.kind == .resourceLimit }
        for (index, original) in scopes.enumerated() {
            try Task.checkCancellation()
            guard visited < options.maxDirectories, entries < options.maxEntries else {
                limited = true
                issues.append(ScanIssue(url: original.root, kind: visited >= options.maxDirectories ? .directoryLimit : .entryLimit,
                                       message: "The shared scan budget was reached. This selected root was not searched."))
                continue
            }
            let scope = Scope(anchor: original.anchor, authorizedRoots: authorizedRoots)
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
                items: [repository], issues: issues, visitedDirectories: 1,
                wasLimited: issues.contains { $0.kind == .resourceLimit }
            )
        }

        // A depth-first stack streams entries and holds only the active path.
        // All roots, chains and streams share an explicit descriptor cap.
        var stack: [(directory: AnchoredDirectory, entries: AnchoredDirectory.Entries, depth: Int)] = []
        do {
            stack.append((scope.anchor, try scope.anchor.entries(), 0))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let resourceLimit = (error as? AnchoredDirectory.AccessError) == .descriptorLimit
            wasLimited = wasLimited || resourceLimit
            issues.append(ScanIssue(url: scope.root, kind: resourceLimit ? .resourceLimit : .directoryUnreadable,
                message: "Could not enumerate the selected directory: \(error.localizedDescription)"))
        }
        var enumeratedEntries = 0
        var reportedDepthLimit = false
        while let frame = stack.last {
            try Task.checkCancellation()
            let name: String
            do {
                guard let next = try frame.entries.next() else { stack.removeLast(); continue }
                name = next
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                stack.removeLast()
                issues.append(ScanIssue(url: frame.directory.url, kind: .directoryUnreadable,
                    message: "Could not continue enumerating this directory: \(error.localizedDescription)"))
                continue
            }
            guard enumeratedEntries < options.maxEntries else {
                wasLimited = true
                issues.append(ScanIssue(url: scope.root, kind: .entryLimit,
                    message: "Stopped after examining \(options.maxEntries) directory entries. Results are partial."))
                break
            }
            enumeratedEntries += 1
            if enumeratedEntries == 1 || enumeratedEntries.isMultiple(of: 64) {
                await progress?(RepositoryScanProgress(root: scope.root, completedRoots: 0, totalRoots: 1,
                    visitedDirectories: visitedDirectories, enumeratedEntries: enumeratedEntries,
                    discoveredRepositories: items.count))
            }
            let directory = frame.directory.url.appendingPathComponent(name)
            do {
                let status = try frame.directory.status(name)
                guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { continue }
                if Self.skippedDirectoryNames.contains(name)
                    || (!options.includeHidden && (name.hasPrefix(".") || status.st_flags & UInt32(UF_HIDDEN) != 0)) {
                    continue
                }
                let depth = frame.depth + 1
                if depth > options.maxDepth {
                    wasLimited = true
                    if !reportedDepthLimit {
                        issues.append(ScanIssue(url: scope.root, kind: .depthLimit,
                            message: "Subfolders deeper than \(options.maxDepth) levels were not searched. Results are partial."))
                        reportedDepthLimit = true
                    }
                    continue
                }
                guard visitedDirectories < options.maxDirectories else {
                    wasLimited = true
                    issues.append(ScanIssue(url: scope.root, kind: .directoryLimit,
                        message: "Stopped after visiting \(options.maxDirectories) directories. Results are partial."))
                    break
                }
                let child = try frame.directory.openDirectory(name)
                visitedDirectories += 1
                if let repository = try discover(in: directory, scope: scope, issues: &issues) {
                    items.append(repository)
                } else {
                    stack.append((child, try child.entries(), depth))
                }
            } catch let failure as MetadataFailure {
                issues.append(failure.issue)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let resourceLimit = (error as? AnchoredDirectory.AccessError) == .descriptorLimit
                wasLimited = wasLimited || resourceLimit
                issues.append(ScanIssue(url: directory, kind: resourceLimit ? .resourceLimit : .directoryUnreadable,
                    message: "Could not inspect this directory: \(error.localizedDescription)"))
            }
        }
        try Task.checkCancellation()
        items.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        return RepositoryScanResult(
            items: items, issues: issues,
            visitedDirectories: visitedDirectories, wasLimited: wasLimited || issues.contains { $0.kind == .resourceLimit },
            enumeratedEntries: enumeratedEntries
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
            items: [item], issues: issues, visitedDirectories: 1, wasLimited: issues.contains { $0.kind == .resourceLimit }
        )
    }

    private struct Scope {
        let anchor: AnchoredDirectory
        var root: URL { anchor.url }
        var components: [String] { root.pathComponents }
        var authorizedRoots: [AnchoredDirectory] = []
        var allowedAnchors: [AnchoredDirectory] { authorizedRoots.isEmpty ? [anchor] : authorizedRoots }
        var allowedRoots: [URL] { allowedAnchors.map(\.url) }

        func metadataAnchor(for url: URL) -> AnchoredDirectory? {
            guard let root = metadataRoot(for: url) else { return nil }
            return allowedAnchors.first { $0.url == root }
        }

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

    private func makeScope(_ input: URL, budget: AnchoredDirectory.Budget = .init()) throws -> Scope {
        guard input.isFileURL, input.host == nil || input.host == "" || input.host == "localhost" else {
            throw RepositoryScannerError.invalidRoot("Choose a local folder to scan.")
        }
        do {
            return Scope(anchor: try AnchoredDirectory.selected(input, budget: budget))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AnchoredDirectory.AccessError where error == .descriptorLimit {
            throw error
        } catch {
            throw RepositoryScannerError.invalidRoot("Could not pin the selected folder: \(error.localizedDescription)")
        }
    }

    private func discover(
        in directory: URL,
        scope: Scope,
        issues: inout [ScanIssue]
    ) throws -> DiscoveredRepository? {
        try Task.checkCancellation()
        let marker = directory.appendingPathComponent(".git", isDirectory: false)
        let attributes: stat
        do {
            try requireSafePath(directory, scope: scope)
            attributes = try metadataStatus(at: marker, scope: scope)
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

        let type = attributes.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFLNK) {
            issues.append(ScanIssue(
                url: marker, kind: .symbolicLinkSkipped,
                message: "The .git marker is a symbolic link and was not followed."
            ))
            return nil
        }
        guard type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) else {
            issues.append(ScanIssue(
                url: marker, kind: .invalidMetadata,
                message: "The .git marker is not a regular file or directory."
            ))
            return nil
        }

        let kind: DiscoveredRepository.Kind = type == mode_t(S_IFDIR) ? .gitRepository : .gitWorktree
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
            let gitAttributes = try metadataStatus(at: gitDirectory, scope: scope)
            guard gitAttributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
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
                    let originalError = error
                    let commonExists: Bool
                    do {
                        _ = try metadataStatus(at: commonFile, scope: scope)
                        commonExists = true
                    } catch {
                        if !isMissingFile(error) { throw error }
                        commonExists = false
                    }
                    if commonExists { throw originalError }
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

    private func anchoredParent(for url: URL, scope: Scope) throws -> AnchoredDirectory {
        guard let anchor = scope.metadataAnchor(for: url) else {
            throw metadataFailure(url, .outsideScope, "Git metadata is outside the selected folders. Branch is unknown.")
        }
        let relative = url.pathComponents.dropFirst(anchor.url.pathComponents.count)
        return try anchor.descendant(relative.dropLast())
    }

    private func metadataStatus(at url: URL, scope: Scope) throws -> stat {
        guard let anchor = scope.metadataAnchor(for: url) else {
            throw metadataFailure(url, .outsideScope, "Git metadata is outside the selected folders. Branch is unknown.")
        }
        do {
            if url.pathComponents == anchor.url.pathComponents {
                try anchor.validateIdentity()
                var status = stat()
                guard Darwin.fstat(anchor.descriptor, &status) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return status
            }
            return try anchoredParent(for: url, scope: scope).status(url.lastPathComponent)
        } catch let error as AnchoredDirectory.AccessError {
            throw metadataFailure(url, error == .symbolicLink ? .symbolicLinkSkipped : (error == .descriptorLimit ? .resourceLimit : .metadataUnreadable),
                "The pinned directory changed or could not be traversed safely. Branch is unknown.")
        }
    }

    /// Validate every untrusted path component without ever reopening it by its
    /// absolute spelling. Dot-dot is handled by metadataPath only after validation.
    private func requireSafePath(_ url: URL, scope: Scope) throws {
        let status = try metadataStatus(at: url, scope: scope)
        guard status.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
            throw metadataFailure(url, .symbolicLinkSkipped, "A symbolic link in the metadata path was not followed. Branch is unknown.")
        }
    }

    private func boundedUTF8(at url: URL, scope: Scope) throws -> String {
        let data: Data
        do {
            let parent = try anchoredParent(for: url, scope: scope)
            data = try parent.readFile(url.lastPathComponent, maximumBytes: Self.maximumMetadataBytes) {
                try beforeMetadataOpen?(url)
            }
        } catch let error as AnchoredDirectory.AccessError {
            throw metadataFailure(url, error == .symbolicLink ? .symbolicLinkSkipped : (error == .descriptorLimit ? .resourceLimit : .metadataUnreadable),
                "The pinned metadata directory changed or could not be read safely. Branch is unknown.")
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
            let attributes = try metadataStatus(at: cursor, scope: scope)
            let expected = mode_t((!isDirectory && offset == remaining.count - 1) ? S_IFREG : S_IFDIR)
            guard attributes.st_mode & mode_t(S_IFMT) == expected else {
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
