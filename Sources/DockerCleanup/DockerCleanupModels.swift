import Foundation

/// No CLI context/configuration is loaded. Every connection is an explicit local socket choice.
struct DockerEndpoint: Equatable, Sendable {
    let name: String
    let socketPath: String

    static var desktop: Self {
        Self(name: "Docker Desktop", socketPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".docker/run/docker.sock").path)
    }
    static let engine = Self(name: "Local Docker Engine", socketPath: "/var/run/docker.sock")
}

struct DockerSocketIdentity: Equatable, Sendable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
}

struct DockerPeerIdentity: Equatable, Sendable {
    let pid: Int32
    let uid: UInt32
    let gid: UInt32
    /// macOS kernel audit token, or Linux kernel pidfd device/inode identity.
    let processToken: [UInt64]
}

struct DockerDaemonIdentity: Equatable, Sendable {
    let endpoint: DockerEndpoint
    let socket: DockerSocketIdentity
    let peer: DockerPeerIdentity
    let id: String
    let name: String
    let version: String
    let operatingSystem: String
    let rootless: Bool
}

struct DockerImage: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let tags: [String]
    let size: Int64
    let sharedSize: Int64?
    let containers: Int?
    let labels: [String: String]
    let created: Int64
    enum CodingKeys: String, CodingKey { case id = "Id", tags = "RepoTags", size = "Size", sharedSize = "SharedSize", containers = "Containers", labels = "Labels", created = "Created" }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        size = try c.decode(Int64.self, forKey: .size)
        sharedSize = try c.decodeIfPresent(Int64.self, forKey: .sharedSize)
        containers = try c.decodeIfPresent(Int.self, forKey: .containers)
        labels = DockerLabels.projectOnly(try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:])
        created = try c.decode(Int64.self, forKey: .created)
    }
    var dangling: Bool { tags.filter { $0 != "<none>:<none>" }.isEmpty }
    var title: String { dangling ? String(id.prefix(19)) : tags.joined(separator: ", ") }
    /// A unique-layer estimate only, never promised freed bytes.
    var uniqueBytes: Int64? {
        guard let sharedSize, size >= 0, sharedSize >= 0, sharedSize <= size else { return nil }
        return size - sharedSize
    }
}

struct DockerContainer: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let imageID: String
    let names: [String]
    let state: String
    let labels: [String: String]
    let created: Int64
    enum CodingKeys: String, CodingKey { case id = "Id", imageID = "ImageID", names = "Names", state = "State", labels = "Labels", created = "Created" }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        imageID = try c.decode(String.self, forKey: .imageID)
        names = try c.decode([String].self, forKey: .names)
        state = try c.decode(String.self, forKey: .state)
        labels = DockerLabels.projectOnly(try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:])
        created = try c.decode(Int64.self, forKey: .created)
    }
    var isStopped: Bool { state == "exited" || state == "created" }
    var title: String { names.joined(separator: ", ") }
}

struct DockerVolume: Decodable, Equatable, Identifiable, Sendable {
    let name: String
    let driver: String
    var id: String { name }
    enum CodingKeys: String, CodingKey { case name = "Name", driver = "Driver" }
}

struct DockerBuildCache: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let inUse: Bool
    let shared: Bool
    let size: Int64
    enum CodingKeys: String, CodingKey { case id = "ID", inUse = "InUse", shared = "Shared", size = "Size" }
}

enum DockerLabels {
    static func projectOnly(_ labels: [String: String]) -> [String: String] {
        labels.filter { ["com.docker.compose.project", "com.docker.compose.service"].contains($0.key) }
    }
}

struct DockerInventory: Sendable {
    let id: UUID
    let capturedAt: Date
    let daemon: DockerDaemonIdentity
    let images: [DockerImage]
    let containers: [DockerContainer]
    let volumes: [DockerVolume]
    let buildCache: [DockerBuildCache]
    func imageIsEligible(_ image: DockerImage) -> Bool {
        DockerValidation.imageID(image.id) && image.containers == 0 &&
            !containers.contains { $0.imageID == image.id }
    }
    func references(to image: DockerImage) -> [DockerContainer] { containers.filter { $0.imageID == image.id } }
}

struct DockerSelection: Equatable, Sendable {
    var imageIDs: Set<String> = []
    var containerIDs: Set<String> = []
    /// Explicit daemon-wide unused-cache operation; never represented as exact row selection.
    var allUnusedBuildCache = false
    var isEmpty: Bool { imageIDs.isEmpty && containerIDs.isEmpty && !allUnusedBuildCache }
}

struct DockerCleanupPlan: Identifiable, Sendable {
    let id: UUID
    let inventory: DockerInventory
    let selection: DockerSelection
    let expiresAt: Date
}

struct DockerCleanupResult: Identifiable, Sendable {
    let id = UUID()
    let daemon: DockerDaemonIdentity
    enum State: String, Sendable { case removed, retained, failed, uncertain, skipped }
    struct Item: Identifiable, Sendable {
        let id: String
        let state: State
        let detail: String
    }
    let items: [Item]
    let inventory: DockerInventory?
    let cancelled: Bool
    let reclaimedCacheBytes: UInt64?
    var hasUncertainty: Bool { inventory == nil || items.contains { $0.state == .uncertain } }
}

enum DockerCleanupError: Error, LocalizedError, Equatable {
    case unavailable, unsafeSocket, malformedResponse, responseTooLarge, timeout, cancelled
    case unsupportedDaemon, changed, invalidSelection, expired, alreadyConsumed
    case daemon(Int)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Local Docker socket unavailable. Start Docker yourself, then retry."
        case .unsafeSocket: "The selected local socket is unavailable, unsafe, or changed."
        case .malformedResponse: "Docker returned an incomplete or unsupported response."
        case .responseTooLarge: "Docker inventory exceeded the bounded response limit."
        case .timeout: "Docker timed out. A sent operation may still complete; refresh before retrying."
        case .cancelled: "Cancelled. An operation already sent to Docker may still complete."
        case .unsupportedDaemon: "This Docker daemon or API version is unsupported."
        case .changed: "Docker identity or selected objects changed. Refresh and review again."
        case .invalidSelection: "The selection includes an in-use, protected, or unknown object."
        case .expired: "This confirmation expired. Review a fresh inventory."
        case .alreadyConsumed: "This confirmation has already been used or dismissed."
        case .daemon(let status):
            status == 409
                ? "Docker refused removal because the object is in use or has multiple tags. Refresh and review it."
                : "Docker refused the request. Refresh and review the result."
        }
    }
}

enum DockerValidation {
    static func imageID(_ value: String) -> Bool { value.hasPrefix("sha256:") && hex(String(value.dropFirst(7))) }
    static func containerID(_ value: String) -> Bool { hex(value) }
    private static func hex(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func safeDisplay(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(512))
    }
}

/// Cross-thread cancellation without cancelling an actor while a mutation is in flight.
final class DockerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func check() throws { if isCancelled { throw DockerCleanupError.cancelled } }
}
