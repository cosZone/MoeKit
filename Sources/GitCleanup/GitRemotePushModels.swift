import Foundation

/// Remote selection is explicit. Repository remote configuration is never read
/// by a transport process and cannot select credentials, URLs, or helpers.
struct GitRemotePushRequest: Equatable, Sendable {
    let finish: GitWorktreeFinishResult
    let remoteURL: String
    let remoteBranch: String
}

struct GitRemotePushPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: GitRemotePushRequest
    let host: String
    let remoteRef: String
    let sourceOID: String
    let expectedRemoteOID: String
    let preparedAt: Date
    let gitVersion: String
}

enum GitRemotePushState: String, Equatable, Sendable {
    /// An independent read observed the exact approved source OID. This is an
    /// observation, not a claim that another writer cannot subsequently change it.
    case verified
    case notUpdated
    case differentOID
    case unknown
}

struct GitRemotePushResult: Identifiable, Equatable, Sendable {
    var id: UUID { plan.id }
    let plan: GitRemotePushPlan
    let state: GitRemotePushState
    let observedOID: String?
    var verified: Bool { state == .verified && observedOID == plan.sourceOID }
}

protocol GitRemotePushExecuting: Sendable {
    /// Consent precedes all network access and all reads of existing Keychain
    /// credentials, including this initial remote inspection.
    func prepare(_ request: GitRemotePushRequest, credentialPermit: GitCleanupPermit) async throws -> GitRemotePushPlan
    func push(_ id: UUID, permit: GitCleanupPermit) async throws -> GitRemotePushResult
    /// A separate read-only reconciliation; never repeats the push.
    func reconcile(_ id: UUID, credentialPermit: GitCleanupPermit) async throws -> GitRemotePushResult
}

enum GitRemotePushFailure: Error, LocalizedError, Equatable {
    case endpoint, reference, unavailable, missingReference, ancestry, changed, expired, inspection
    var errorDescription: String? {
        switch self {
        case .endpoint: "Enter an exact HTTPS repository URL with a plain ASCII DNS host and path. Usernames, ports, escapes, queries, redirects, and other protocols are not supported."
        case .reference: "This remote branch name is not supported. No wildcard, deletion, or force refspec is available."
        case .unavailable: "The verified Apple HTTPS transport is unavailable. Install Apple Command Line Tools or Xcode; both worktrees are retained."
        case .missingReference: "The exact remote branch does not exist. This flow does not create remote branches."
        case .ancestry: "The remote commit cannot be proved to be an ancestor of the merged commit using local objects. No fetch or force push was attempted."
        case .changed: "The local target or exact remote branch changed after review. Inspect again before pushing."
        case .expired: "The remote confirmation expired or was already used. Inspect again."
        case .inspection: "The remote branch could not be verified. Check access in your Git client; no credentials or raw server diagnostics are displayed."
        }
    }
}

/// Deliberately narrower than general RFC URL/ref syntax. Both Swift and the
/// compiled helper validate this contract independently before network access.
struct GitRemoteEndpoint: Equatable, Sendable {
    let url: String
    let host: String
    let path: String
    init(_ value: String) throws {
        guard value.utf8.count <= 2048, value.hasPrefix("https://"),
              value.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw GitRemotePushFailure.endpoint }
        let rest = value.dropFirst(8)
        guard let slash = rest.firstIndex(of: "/") else { throw GitRemotePushFailure.endpoint }
        let host = String(rest[..<slash]), path = String(rest[rest.index(after: slash)...])
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("xn--") &&
                  label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
              }), labels.last!.utf8.allSatisfy({ (97...122).contains($0) }),
              !["localhost", "local", "internal"].contains(String(labels.last!)),
              !path.isEmpty, path.utf8.count <= 1024,
              path.utf8.allSatisfy({ Self.atom($0) || $0 == 47 }),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("-") })
        else { throw GitRemotePushFailure.endpoint }
        self.url = value; self.host = host; self.path = path
    }
    static func ref(branch: String) throws -> String {
        guard !branch.isEmpty, branch.utf8.count <= 240,
              branch.utf8.allSatisfy({ atom($0) || $0 == 47 }), !branch.contains(".."),
              branch.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasPrefix("-") && !$0.hasSuffix(".") && !$0.hasSuffix(".lock")
              }) else { throw GitRemotePushFailure.reference }
        return "refs/heads/" + branch
    }
    static func oid(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) && value != String(repeating: "0", count: 40)
    }
    private static func atom(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95].contains(byte)
    }
}
