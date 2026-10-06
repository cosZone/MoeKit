import Foundation
import Darwin

/// Directory handles pin objects, rather than repeatedly resolving absolute paths.
/// Every child is opened relative to its parent without following symlinks. The
/// parent/name identity checks detect observable renames/replacements, including
/// ancestors above a selected root. They are not a filesystem-wide snapshot: an
/// object may move after a check, but later opens still use the pinned descriptors.
final class AnchoredDirectory {
    enum AccessError: Error, Equatable {
        case symbolicLink
        case notDirectory
        case changed
        case invalidComponent
        case descriptorLimit
    }

    /// One scan shares this cap across selected-root chains and traversal streams.
    final class Budget {
        static let maximumDescriptors = 128
        private(set) var openDescriptors = 0
        func acquire() throws {
            guard openDescriptors < Self.maximumDescriptors else { throw AccessError.descriptorLimit }
            openDescriptors += 1
        }
        func release() { openDescriptors -= 1 }
    }

    let url: URL
    let descriptor: Int32
    private let identity: stat
    private let budget: Budget
    private let parent: AnchoredDirectory?
    private let name: String?

    private init(descriptor: Int32, url: URL, parent: AnchoredDirectory?, name: String?, budget: Budget) throws {
        self.descriptor = descriptor
        self.url = url
        self.parent = parent
        self.name = name
        self.budget = budget
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw Self.posixError() }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw AccessError.notDirectory }
        identity = status
    }

    deinit { Darwin.close(descriptor); budget.release() }

    /// Only the explicitly selected input is canonicalized. Its final component
    /// must be a directory, not a symlink; aliases in its ancestors (e.g. /var) are
    /// supported. The before/open identity comparison rejects a changed selection.
    static func selected(_ input: URL, budget: Budget = Budget(), reusing roots: [AnchoredDirectory] = []) throws -> AnchoredDirectory {
        try Task.checkCancellation()
        var selectedStatus = stat()
        // URL directory representations may end in a slash; lstat on a trailing
        // slash would follow a final symlink. Use the slash-free path spelling.
        var selectedPath = input.path
        while selectedPath.count > 1 && selectedPath.hasSuffix("/") { selectedPath.removeLast() }
        guard input.isFileURL, !selectedPath.utf8.contains(0) else { throw AccessError.invalidComponent }
        let canonical = try selectedPath.withCString { path -> URL in
            guard Darwin.lstat(path, &selectedStatus) == 0 else { throw posixError() }
            guard selectedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw AccessError.notDirectory }
            guard let resolved = Darwin.realpath(path, nil) else { throw posixError() }
            defer { Darwin.free(resolved) }
            guard let path = String(validatingCString: resolved) else { throw AccessError.invalidComponent }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        // Reuse only existing root-establishment chains, not discovered children.
        // Their lifetime is owned by the scan's roots, so Budget has no retain cycle.
        var shared: AnchoredDirectory?
        for root in roots {
            var candidate: AnchoredDirectory? = root
            while let current = candidate {
                if canonical.pathComponents.starts(with: current.url.pathComponents),
                   shared == nil || current.url.pathComponents.count > shared!.url.pathComponents.count {
                    shared = current
                }
                candidate = current.parent
            }
        }
        var directory: AnchoredDirectory
        if let shared {
            try shared.validateIdentity() // Never reopen a changed cached ancestor.
            directory = shared
        } else {
            try budget.acquire()
            let descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { budget.release(); throw posixError() }
            do {
                directory = try AnchoredDirectory(descriptor: descriptor, url: URL(fileURLWithPath: "/"), parent: nil, name: nil, budget: budget)
            } catch {
                Darwin.close(descriptor)
                budget.release()
                throw error
            }
        }
        for component in canonical.pathComponents.dropFirst(directory.url.pathComponents.count) {
            directory = try directory.openDirectory(component)
        }
        guard sameIdentity(selectedStatus, directory.identity) else { throw AccessError.changed }
        try directory.validateIdentity()
        return directory
    }

    func validateIdentity() throws {
        try Task.checkCancellation()
        if let parent, let name {
            try parent.validateIdentity()
            let current = try parent.statusUnchecked(name)
            guard Self.sameIdentity(identity, current) else { throw AccessError.changed }
        }
    }

    func status(_ name: String) throws -> stat {
        try validateIdentity()
        let result = try statusUnchecked(name)
        try validateIdentity()
        return result
    }

    func openDirectory(_ name: String) throws -> AnchoredDirectory {
        try Self.checkComponent(name)
        try validateIdentity()
        try budget.acquire()
        let descriptor = Darwin.openat(self.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            budget.release()
            // Darwin can report ENOTDIR for O_DIRECTORY|O_NOFOLLOW on a symlink.
            if let status = try? statusUnchecked(name), status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw AccessError.symbolicLink
            }
            throw Self.posixError(code)
        }
        let child: AnchoredDirectory
        do {
            child = try AnchoredDirectory(descriptor: descriptor, url: url.appendingPathComponent(name), parent: self, name: name, budget: budget)
        } catch {
            Darwin.close(descriptor)
            budget.release()
            throw error
        }
        try child.validateIdentity()
        return child
    }

    func descendant(_ components: ArraySlice<String>) throws -> AnchoredDirectory {
        var result = self
        for component in components { result = try result.openDirectory(component) }
        return result
    }

    func readFile(_ name: String, maximumBytes: Int, beforeOpen: () throws -> Void = {}) throws -> Data {
        try Self.checkComponent(name)
        try validateIdentity()
        try beforeOpen()
        // The hook models a concurrent replacement after the directory was opened.
        // No absolute pathname is used here, even when that replacement happens.
        let descriptor = Darwin.openat(self.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw BoundedRegularFileReader.ReadError.symbolicLink }
            throw Self.posixError()
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0 else { throw Self.posixError() }
        func validate() throws {
            try validateIdentity()
            guard Self.sameIdentity(opened, try statusUnchecked(name)) else { throw AccessError.changed }
        }
        let data = try BoundedRegularFileReader.read(descriptor: descriptor, maximumBytes: maximumBytes, validateAfterOpen: validate)
        try validate()
        return data
    }

    func entries() throws -> Entries { try Entries(directory: self) }

    final class Entries {
        private let directory: AnchoredDirectory
        private let stream: UnsafeMutablePointer<DIR>

        init(directory: AnchoredDirectory) throws {
            try directory.validateIdentity()
            // An independent open description keeps stream offsets separate from
            // any other enumeration; fdopendir owns this descriptor on success.
            try directory.budget.acquire()
            let descriptor = Darwin.openat(directory.descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { directory.budget.release(); throw AnchoredDirectory.posixError() }
            guard let stream = Darwin.fdopendir(descriptor) else {
                let error = AnchoredDirectory.posixError()
                Darwin.close(descriptor)
                directory.budget.release()
                throw error
            }
            self.directory = directory
            self.stream = stream
        }

        deinit { Darwin.closedir(stream); directory.budget.release() }

        func next() throws -> String? {
            try directory.validateIdentity()
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let entry = Darwin.readdir(stream) else {
                    if errno != 0 { throw AnchoredDirectory.posixError() }
                    return nil
                }
                let name: String
                do { name = try DarwinDirectoryEntry.name(entry) }
                catch { throw AccessError.invalidComponent }
                if name != "." && name != ".." { return name }
            }
        }
    }

    private func statusUnchecked(_ name: String) throws -> stat {
        try Self.checkComponent(name)
        var result = stat()
        guard Darwin.fstatat(descriptor, name, &result, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posixError() }
        return result
    }

    private static func checkComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw AccessError.invalidComponent
        }
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode & mode_t(S_IFMT) == rhs.st_mode & mode_t(S_IFMT)
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
