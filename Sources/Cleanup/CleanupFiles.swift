import Darwin
import Foundation

struct CleanupEnvironment: Sendable {
    let home: URL
    let caches: URL
    let recovery: URL
    let trash: URL
    let enforceProductionPolicy: Bool
    static var user: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return .init(home: home, caches: home.appendingPathComponent("Library/Caches"),
                     recovery: home.appendingPathComponent("Library/Application Support/MoeKit/CacheRecovery"),
                     trash: home.appendingPathComponent(".Trash"), enforceProductionPolicy: true)
    }
}

/// Complete, bounded descriptor-relative inventory. Links are inventoried as
/// leaves; their destinations are never opened, enumerated, or removed.
enum CleanupFiles {
    static let maximumEntries = 25_000
    static let maximumTargets = 16
    static let cacheSignature = Data("Signature: 8a477f597d28d172789f06886806bc55".utf8)

    static func validateNamespace(_ directory: InstallerDirectoryAnchor, environment: CleanupEnvironment) throws {
        try directory.validate()
        try InstallerFileAccess.rejectMutationGrantingACL(directory.fd)
        if environment.enforceProductionPolicy { try directory.validateTrustedMutationAncestry() }
    }
    static func validateRoot(_ root: InstallerDirectoryAnchor, environment: CleanupEnvironment) throws {
        guard root.url.pathComponents.starts(with: environment.home.pathComponents), root.url != environment.home else {
            throw CleanupFailure.refused(String(localized: "Choose a cache location inside your own home folder."))
        }
        try validateNamespace(root, environment: environment)
        var ancestor: InstallerDirectoryAnchor? = root
        while let node = ancestor {
            var metadata = stat()
            if fstatat(node.fd, ".git", &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                throw CleanupFailure.refused(String(localized: "Git metadata was found in a containing folder: \(InstallerPathDisplay.quoted(node.url.path)). Cleanup remains protected."))
            }
            guard errno == ENOENT else {
                let reason = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription
                throw CleanupFailure.refused(String(localized: "Cannot verify Git ancestry at \(InstallerPathDisplay.quoted(node.url.path)): \(reason)"))
            }
            ancestor = node.parent
        }
        try rejectBareGitAncestors(root)
        try validateObject(root.identity, expectedDevice: root.identity.device, kind: .directory)
        if environment.enforceProductionPolicy { try InstallerFileAccess.validateVolume(root.fd, url: root.url) }
        try InstallerFileAccess.rejectCloudAttributes(root.fd)
    }
    private static func rejectBareGitAncestors(_ root: InstallerDirectoryAnchor) throws {
        var current: InstallerDirectoryAnchor? = root
        while let node = current {
            var present = 0
            for name in ["HEAD", "objects", "refs"] {
                var metadata = stat()
                if fstatat(node.fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { present += 1 }
                else if errno != ENOENT { throw CleanupFailure.changed }
            }
            guard present != 3 else { throw CleanupFailure.refused(String(localized: "Git metadata or a protected credential/configuration name was found inside this candidate.")) }
            try node.validate(); current = node.parent
        }
    }
    static func names(_ directory: InstallerDirectoryAnchor, limit: Int = maximumEntries, honorCancellation: Bool = true) throws -> [String] {
        try directory.validate()
        let duplicate = dup(directory.fd)
        guard duplicate >= 0 else { throw CleanupFailure.changed }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw CleanupFailure.changed }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while true {
            if honorCancellation { try Task.checkCancellation() }
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw CleanupFailure.changed }
                break
            }
            var raw = entry.pointee.d_name
            let bytes = withUnsafeBytes(of: &raw) { Data($0.prefix(while: { $0 != 0 })) }
            guard let name = String(data: bytes, encoding: .utf8) else {
                throw CleanupFailure.refused(String(localized: "A filename could not be displayed without changing its bytes."))
            }
            if name == "." || name == ".." { continue }
            guard names.count < limit else { throw CleanupFailure.limit }
            try InstallerFileAccess.basename(name)
            names.append(name)
        }
        try directory.validate()
        return names.sorted()
    }
    static func evidence(parent: InstallerDirectoryAnchor, candidate: InstallerDirectoryAnchor, environment: CleanupEnvironment) throws -> String {
        let name = candidate.url.lastPathComponent.lowercased()
        let protectedWords = ["keychain", "credential", "password", "security", "auth", "1password", "bitwarden", "moekit"]
        guard !name.hasPrefix("com.apple."), !protectedWords.contains(where: { name.contains($0) }) else {
            throw CleanupFailure.refused(String(localized: "This system, security, or MoeKit cache is protected in this version."))
        }
        if parent.url.path == environment.caches.path {
            return String(localized: "Direct child of your macOS user Caches folder. This location suggests cache data; review the contents and confirm that you can regenerate them.")
        }
        let file = try InstallerFileDescriptor(parent: candidate, name: "CACHEDIR.TAG")
        let identity = try InstallerFileAccess.snapshot(file.fd)
        try validateObject(identity, expectedDevice: candidate.identity.device, kind: .file)
        let data = try BoundedRegularFileReader.read(descriptor: file.fd, maximumBytes: 64 * 1024)
        guard data.starts(with: cacheSignature), identity == (try InstallerFileAccess.snapshotAt(candidate.fd, "CACHEDIR.TAG")) else {
            throw CleanupFailure.refused(String(localized: "The cache tag is missing, changed, or does not contain the standard signature."))
        }
        return String(localized: "Standard CACHEDIR.TAG signature found. The tag is a claim by the folder creator, not permission or proof that every file is disposable.")
    }
    static func protect(_ target: URL, paths: [String], originalIdentity: InstallerFileSnapshot? = nil) throws {
        guard paths.count <= 2_002 else { throw CleanupFailure.limit }
        let selected = try InstallerFileAccess.components(target)
        let selectedFolded = selected.map(foldedComponent)
        // Recovery targets are normally absent after Trash. Anchor their original
        // parent, while retaining the receipt-bound original root identity.
        let candidate = try InstallerDirectoryAnchor.open(originalIdentity == nil ? target : target.deletingLastPathComponent())
        let selectedIdentity = originalIdentity ?? candidate.identity
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let protected = try InstallerFileAccess.components(url)
            let protectedFolded = protected.map(foldedComponent)
            // Conservative even on case-sensitive volumes; diacritic/width
            // equivalence may refuse extra locations but cannot widen consent.
            guard !selectedFolded.starts(with: protectedFolded), !protectedFolded.starts(with: selectedFolded) else {
                throw CleanupFailure.refused(String(localized: "A saved project, worktree, or protected control location overlaps this cache."))
            }
            var metadata = stat()
            if lstat(url.path, &metadata) != 0 {
                // Missing protected roots confer no inode, but lexical protection
                // above remains. Permission errors never silently clear scope.
                guard errno == ENOENT else {
                    let reason = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription
                    throw CleanupFailure.refused(String(localized: "Cannot verify protected location \(InstallerPathDisplay.quoted(url.path)): \(reason)"))
                }
                continue
            }
            // Comparing overlap requires the protected object's identity, not
            // permission to enumerate its contents. In particular, macOS may
            // allow lstat(~/.Trash) while refusing open(~/.Trash). Do not make
            // every unrelated user cache depend on access to Trash contents.
            let parent: InstallerDirectoryAnchor
            do { parent = try InstallerDirectoryAnchor.open(url.deletingLastPathComponent()) }
            catch { throw CleanupFailure.refused(inspectionMessage(error, stage: String(localized: "Protected location parent"), url: url.deletingLastPathComponent())) }
            // Keep the descriptor owner alive through the final borrowed-fd
            // snapshot as well, including optimized Release/ASan builds.
            defer { withExtendedLifetime(parent) {} }
            let named = try InstallerFileAccess.snapshotAt(parent.fd, url.lastPathComponent)
            let protectedIdentity: InstallerFileSnapshot
            switch named.mode & UInt32(S_IFMT) {
            case UInt32(S_IFDIR): protectedIdentity = named
            case UInt32(S_IFREG): protectedIdentity = parent.identity // Metadata file protects its entire containing folder.
            default:
                throw CleanupFailure.refused(String(localized: "The protected location is a link or unsupported object: \(InstallerPathDisplay.quoted(url.path))"))
            }
            func containsIdentity(_ chain: InstallerDirectoryAnchor, _ identity: InstallerFileSnapshot) -> Bool {
                var current: InstallerDirectoryAnchor? = chain
                while let node = current {
                    if node.identity.device == identity.device && node.identity.inode == identity.inode { return true }
                    current = node.parent
                }
                return false
            }
            guard !containsIdentity(candidate, protectedIdentity),
                  !containsIdentity(parent, selectedIdentity),
                  !(named.device == selectedIdentity.device && named.inode == selectedIdentity.inode) else {
                throw CleanupFailure.refused(String(localized: "A saved project, worktree, or protected control location overlaps this cache."))
            }
            try parent.validate()
            let after = try InstallerFileAccess.snapshotAt(parent.fd, url.lastPathComponent)
            guard named.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) ? named.matchesDirectory(after) : named == after else { throw CleanupFailure.changed }
        }
        try candidate.validate()
    }
    static func inspectionMessage(_ error: any Error, stage: String, url: URL) -> String {
        let reason: String
        if let failure = error as? InstallerTrashFailure {
            switch failure {
            case .protected: reason = String(localized: "A Git or protected project location overlaps this folder.")
            case .changed: reason = String(localized: "The path could not be opened without following links, or its identity changed.")
            case .unsupported: reason = String(localized: "This check found unsupported ownership, permissions, ACL, file flags, or volume metadata.")
            default: reason = failure.localizedDescription
            }
        } else { reason = error.localizedDescription }
        return String(localized: "\(stage) at \(InstallerPathDisplay.quoted(url.path)): \(reason)")
    }

    private static func foldedComponent(_ value: String) -> String {
        value.decomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func manifest(_ directory: InstallerDirectoryAnchor, environment: CleanupEnvironment, honorCancellation: Bool = true,
                         maximumEntries: Int = CleanupFiles.maximumEntries, deadline: Date = Date().addingTimeInterval(30)) throws -> CleanupManifest {
        var entries: [CleanupEntry] = [], bytes: Int64 = 0
        var pathAndLinkBytes = 0
        func walk(_ node: InstallerDirectoryAnchor, path: String, depth: Int) throws {
            if honorCancellation { try Task.checkCancellation() }
            guard depth <= 64, Date() < deadline, entries.count < maximumEntries else { throw CleanupFailure.limit }
            try node.validate()
            let before = try InstallerFileAccess.snapshot(node.fd)
            try validateObject(before, expectedDevice: directory.identity.device, kind: .directory)
            do { try InstallerFileAccess.rejectMutationGrantingACL(node.fd) }
            catch { throw CleanupFailure.refused(inspectionMessage(error, stage: String(localized: "Write-access ACL validation"), url: node.url)) }
            do { try InstallerFileAccess.rejectCloudAttributes(node.fd) }
            catch { throw CleanupFailure.refused(inspectionMessage(error, stage: String(localized: "Cloud metadata validation"), url: node.url)) }
            let childNames = try names(node, limit: maximumEntries - entries.count, honorCancellation: honorCancellation)
            // Never delete repository objects, worktree metadata, or a copied
            // credential file merely because a parent says it is a cache.
            let sensitive = [".git", ".hg", ".svn", ".ssh", ".gnupg", ".aws", ".kube", ".env", "id_rsa", "id_ed25519"]
            guard !childNames.contains(where: { sensitive.contains($0.lowercased()) || isProtectedSecretName($0) }),
                  !Set(["head", "objects", "refs"]).isSubset(of: Set(childNames.map { $0.lowercased() })) else {
                throw CleanupFailure.refused(String(localized: "Git metadata or a protected credential/configuration name was found inside this candidate."))
            }
            entries.append(.init(relativePath: path, kind: .directory, identity: before, linkDestination: nil))
            for name in childNames {
                if honorCancellation { try Task.checkCancellation() }
                guard Date() < deadline, entries.count < maximumEntries else { throw CleanupFailure.limit }
                let childPath = path.isEmpty ? name : path + "/" + name
                pathAndLinkBytes += childPath.utf8.count
                guard pathAndLinkBytes <= 4 * 1024 * 1024 else { throw CleanupFailure.limit }
                guard childPath.utf8.count <= 4096 else { throw CleanupFailure.limit }
                let identity = try InstallerFileAccess.snapshotAt(node.fd, name)
                switch identity.mode & UInt32(S_IFMT) {
                case UInt32(S_IFDIR):
                    let child = try node.child(name)
                    guard identity == (try InstallerFileAccess.snapshot(child.fd)) else { throw CleanupFailure.changed }
                    try walk(child, path: childPath, depth: depth + 1)
                case UInt32(S_IFREG):
                    try validateObject(identity, expectedDevice: directory.identity.device, kind: .file)
                    let file = try InstallerFileDescriptor(parent: node, name: name)
                    guard identity == (try InstallerFileAccess.snapshot(file.fd)) else { throw CleanupFailure.changed }
                    do { try InstallerFileAccess.rejectMutationGrantingACL(file.fd) }
                    catch { throw CleanupFailure.refused(inspectionMessage(error, stage: String(localized: "Write-access ACL validation"), url: node.url.appendingPathComponent(name))) }
                    do { try InstallerFileAccess.rejectCloudAttributes(file.fd) }
                    catch { throw CleanupFailure.refused(inspectionMessage(error, stage: String(localized: "Cloud metadata validation"), url: node.url.appendingPathComponent(name))) }
                    guard identity == (try InstallerFileAccess.snapshotAt(node.fd, name)) else { throw CleanupFailure.changed }
                    let sum = bytes.addingReportingOverflow(identity.bytes)
                    guard !sum.overflow else { throw CleanupFailure.limit }
                    bytes = sum.partialValue
                    entries.append(.init(relativePath: childPath, kind: .file, identity: identity, linkDestination: nil))
                case UInt32(S_IFLNK):
                    try validateObject(identity, expectedDevice: directory.identity.device, kind: .symbolicLink)
                    var buffer = [UInt8](repeating: 0, count: 4097)
                    let capacity = buffer.count
                    let count = buffer.withUnsafeMutableBytes { bytes in
                        readlinkat(node.fd, name, bytes.baseAddress, capacity)
                    }
                    guard count >= 0, count < buffer.count,
                          identity == (try InstallerFileAccess.snapshotAt(node.fd, name)) else { throw CleanupFailure.changed }
                    pathAndLinkBytes += count
                    guard pathAndLinkBytes <= 4 * 1024 * 1024 else { throw CleanupFailure.limit }
                    entries.append(.init(relativePath: childPath, kind: .symbolicLink, identity: identity, linkDestination: Data(buffer.prefix(count))))
                default:
                    throw CleanupFailure.refused(String(localized: "A socket, device, pipe, or unsupported entry is present. Close the owning app and inspect again."))
                }
            }
            guard before == (try InstallerFileAccess.snapshot(node.fd)), childNames == (try names(node, honorCancellation: honorCancellation)) else { throw CleanupFailure.changed }
            try node.validate()
        }
        try walk(directory, path: "", depth: 0)
        return .init(entries: entries, logicalBytes: bytes)
    }
    /// A Trash item may also be a file or a symbolic link. Reuses the same
    /// ownership, no-follow and ACL policy as directory manifest leaves.
    static func manifest(parent: InstallerDirectoryAnchor, name: String, environment: CleanupEnvironment,
                         maximumEntries: Int = CleanupFiles.maximumEntries, deadline: Date = Date().addingTimeInterval(30)) throws -> CleanupManifest {
        try Task.checkCancellation()
        guard maximumEntries > 0, Date() < deadline else { throw CleanupFailure.limit }
        try parent.validate()
        let identity = try InstallerFileAccess.snapshotAt(parent.fd, name)
        if identity.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) {
            let directory = try parent.child(name)
            guard identity == (try InstallerFileAccess.snapshot(directory.fd)) else { throw CleanupFailure.changed }
            return try manifest(directory, environment: environment, maximumEntries: maximumEntries, deadline: deadline)
        }
        let kind: CleanupEntry.Kind
        var destination: Data?
        switch identity.mode & UInt32(S_IFMT) {
        case UInt32(S_IFREG):
            kind = .file
            try validateObject(identity, expectedDevice: parent.identity.device, kind: kind)
            let file = try InstallerFileDescriptor(parent: parent, name: name)
            guard identity == (try InstallerFileAccess.snapshot(file.fd)) else { throw CleanupFailure.changed }
            try InstallerFileAccess.rejectMutationGrantingACL(file.fd)
            try InstallerFileAccess.rejectCloudAttributes(file.fd)
        case UInt32(S_IFLNK):
            kind = .symbolicLink
            try validateObject(identity, expectedDevice: parent.identity.device, kind: kind)
            var bytes = [UInt8](repeating: 0, count: 4097)
            let capacity = bytes.count
            let count = bytes.withUnsafeMutableBytes { readlinkat(parent.fd, name, $0.baseAddress, capacity) }
            guard count >= 0, count < capacity else { throw CleanupFailure.changed }
            destination = Data(bytes.prefix(count))
        default: throw CleanupFailure.refused(String(localized: "A socket, device, pipe, or unsupported entry is present. Close the owning app and inspect again."))
        }
        guard identity == (try InstallerFileAccess.snapshotAt(parent.fd, name)) else { throw CleanupFailure.changed }
        try parent.validate()
        return .init(entries: [.init(relativePath: "", kind: kind, identity: identity, linkDestination: destination)],
                     logicalBytes: kind == .file ? identity.bytes : 0)
    }
    static func matchesAfterMove(_ expected: CleanupManifest, _ actual: CleanupManifest) -> Bool {
        guard expected.logicalBytes == actual.logicalBytes, expected.entries.count == actual.entries.count else { return false }
        return zip(expected.entries, actual.entries).allSatisfy { a, b in
            a.relativePath == b.relativePath && a.kind == b.kind && a.linkDestination == b.linkDestination
                && (a.relativePath.isEmpty ? a.identity.matchesCaptured(b.identity) : a.identity == b.identity)
        }
    }
    static func isProtectedSecretName(_ name: String) -> Bool {
        let value = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return value.hasPrefix(".env.") || ["vault", "keychain", "1password", "bitwarden"].contains(where: { value.contains($0) })
    }
    private static func validateObject(_ value: InstallerFileSnapshot, expectedDevice: UInt64, kind: CleanupEntry.Kind) throws {
        guard geteuid() != 0, value.uid == geteuid(), value.device == expectedDevice,
              value.flags & ~UInt32(UF_NODUMP) == 0, value.bytes >= 0, value.links > 0,
              kind == .symbolicLink || value.mode & 0o022 == 0 else {
            throw CleanupFailure.refused(String(localized: "Ownership, volume, file flags, or write permissions make this cache unsupported. Permissions were not changed."))
        }
    }
}
