import Foundation

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

    public var id: String { url.path }

    public init(url: URL, name: String, kind: Kind, branch: String?) {
        self.url = url
        self.name = name
        self.kind = kind
        self.branch = branch
    }
}

public struct ScanOptions: Sendable, Hashable {
    /// The selected root has depth zero. Repositories at this depth are included.
    public let maxDepth: Int
    /// Includes the selected root; excluded and symbolic-link directories do not count.
    public let maxDirectories: Int
    public let includeHidden: Bool

    public init(maxDepth: Int = 4, maxDirectories: Int = 2_000, includeHidden: Bool = false) {
        self.maxDepth = maxDepth
        self.maxDirectories = maxDirectories
        self.includeHidden = includeHidden
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

    public init(
        items: [DiscoveredRepository],
        issues: [ScanIssue],
        visitedDirectories: Int,
        wasLimited: Bool
    ) {
        self.items = items
        self.issues = issues
        self.visitedDirectories = visitedDirectories
        self.wasLimited = wasLimited
    }
}

public enum RepositoryScannerError: Error, Sendable, LocalizedError {
    case invalidOptions
    case invalidRoot(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "Scan depth must be zero or greater and the directory limit must be positive."
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

    /// Finds Git repositories only. Use `inspectFolder` to explicitly add a plain folder.
    public func scan(root: URL, options: ScanOptions = ScanOptions()) async throws -> RepositoryScanResult {
        try Task.checkCancellation()
        guard options.maxDepth >= 0, options.maxDirectories > 0 else {
            throw RepositoryScannerError.invalidOptions
        }
        let scope = try makeScope(root)
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
            guard enumeratedEntries < Self.maximumEnumeratedEntries else {
                wasLimited = true
                issues.append(ScanIssue(
                    url: scope.root, kind: .entryLimit,
                    message: "Stopped after examining \(Self.maximumEnumeratedEntries) directory entries. Results are partial."
                ))
                break
            }
            enumeratedEntries += 1

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
            visitedDirectories: visitedDirectories, wasLimited: wasLimited
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
            // Normalize system aliases in ancestors (for example /var on macOS).
            // The selected folder itself was checked above and may not be a symlink.
            let root = selected.resolvingSymlinksInPath().standardizedFileURL
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
        } catch let failure as MetadataFailure {
            issues.append(failure.issue)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            issues.append(ScanIssue(
                url: marker, kind: .metadataUnreadable,
                message: "Branch is unknown because Git metadata could not be read: \(error.localizedDescription)"
            ))
        }
        return DiscoveredRepository(
            url: directory, name: directory.lastPathComponent, kind: kind, branch: branch
        )
    }

    /// Reject outside paths before accessing any of their metadata. Never resolve an
    /// untrusted pointer's symlinks; inspect each component inside the scope instead.
    private func requireSafePath(_ url: URL, scope: Scope) throws {
        try Task.checkCancellation()
        guard scope.contains(url) else {
            throw metadataFailure(url, .outsideScope, "Git metadata is outside the selected folder. Branch is unknown.")
        }
        var cursor = scope.root
        let relative = url.pathComponents.dropFirst(scope.components.count)
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
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try requireSafePath(url, scope: scope)
        guard try handle.seekToEnd() <= UInt64(Self.maximumMetadataBytes) else {
            throw metadataFailure(url, .metadataTooLarge, "Git metadata exceeds the 16 KiB safety limit. Branch is unknown.")
        }
        try handle.seek(toOffset: 0)
        // Read at most 16 KiB, including when the file changes after its size check.
        let data = try handle.read(upToCount: Self.maximumMetadataBytes) ?? Data()
        guard try handle.seekToEnd() <= UInt64(Self.maximumMetadataBytes) else {
            throw metadataFailure(url, .metadataTooLarge, "Git metadata grew beyond the 16 KiB safety limit. Branch is unknown.")
        }
        try Task.checkCancellation()
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
        let path = String(line.dropFirst("gitdir: ".count))
        guard !path.isEmpty, !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw metadataFailure(marker, .invalidMetadata, "The Git directory pointer is empty or contains control characters.")
        }
        // Walk the text lexically, never standardize or resolve an untrusted URL.
        // Check each directory BEFORE handling the next component: `link/../safe`
        // must reject `link`, rather than erasing it and reading a different target.
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var cursor: URL
        let remaining: ArraySlice<String>
        if path.hasPrefix("/") {
            let rootComponents = scope.components.filter { $0 != "/" }
            guard components.starts(with: rootComponents) else {
                throw metadataFailure(marker, .outsideScope, "This worktree's Git metadata is outside the selected folder. Branch is unknown.")
            }
            cursor = scope.root
            remaining = components.dropFirst(rootComponents.count)
        } else {
            cursor = repository
            remaining = components[...]
        }
        try requireSafePath(cursor, scope: scope)
        for component in remaining {
            try Task.checkCancellation()
            if component == "." { continue }
            if component == ".." {
                guard cursor.pathComponents.count > scope.components.count else {
                    throw metadataFailure(marker, .outsideScope, "This worktree's Git metadata path leaves the selected folder. Branch is unknown.")
                }
                cursor.deleteLastPathComponent()
            } else {
                cursor.appendPathComponent(component, isDirectory: true)
            }
            try requireSafePath(cursor, scope: scope)
            let attributes = try fileManager.attributesOfItem(atPath: cursor.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw metadataFailure(cursor, .invalidMetadata, "The Git metadata path contains a non-directory component.")
            }
        }
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
        return error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }
}
