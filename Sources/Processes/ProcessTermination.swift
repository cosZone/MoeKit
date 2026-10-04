import Foundation

/// A request for exactly these records. No names, groups, descendants, or caller-
/// supplied signal numbers can become targets. SIGKILL needs another review.
enum ProcessStopMode: String, Sendable { case graceful, force }
enum ProcessPresence: Equatable, Sendable { case running, exited, unknown }

struct ProcessStopReview: Identifiable, Sendable {
    let id: UUID
    let mode: ProcessStopMode
    let records: [ProcessInventoryRecord]
    let createdAt: Date
}

struct ProcessStopResult: Identifiable, Sendable {
    let record: ProcessInventoryRecord
    let mode: ProcessStopMode
    let signalSubmitted: Bool
    let presence: ProcessPresence
    let message: String
    var id: ProcessIdentity { record.identity }
}

protocol ProcessTerminationSystem: Sendable {
    func inspect(_ identities: [ProcessIdentity]) async throws -> ProcessSnapshot
    func signal(_ record: ProcessInventoryRecord, mode: ProcessStopMode, authority: ProcessSignalAuthority) async throws
    func presence(of identity: ProcessIdentity) async -> ProcessPresence
}

enum ProcessTerminationError: Error, Equatable, LocalizedError {
    case unavailable, changed, protectedTarget, expired, forceNotReviewed, selectionLimit
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "The exact process identity or required metadata could not be verified. No fallback signal is allowed.")
        case .changed: String(localized: "A selected process changed or exited. Scan and review again.")
        case .protectedTarget: String(localized: "This selection includes a protected application, browser, shared service, system process, or MoeKit ancestor. Remove protected rows before continuing.")
        case .expired: String(localized: "This confirmation expired or was already used. Review the exact targets again.")
        case .forceNotReviewed: String(localized: "Force stop is available only for the exact processes still running after your confirmed graceful stop.")
        case .selectionLimit: String(localized: "Select between 1 and 16 exact processes for one confirmation.")
        }
    }
}

/// Owns the one-use authority; UI cannot submit arbitrary records at execution.
/// All preflight is completed before the first signal. The batch is NOT atomic:
/// each target is checked again and receives an individual result.
actor ProcessTerminationExecutor {
    private let system: any ProcessTerminationSystem
    private let now: @Sendable () -> TimeInterval
    private var pending: (review: ProcessStopReview, expires: TimeInterval)?
    private var forceEligible: Set<ProcessIdentity> = []
    private var generation: UInt64 = 0
    private var activeAuthority: ProcessSignalAuthority?

    init(system: any ProcessTerminationSystem = NativeProcessTerminationSystem(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.system = system; self.now = now
    }

    func invalidate(clearForceEligibility: Bool = true) {
        generation &+= 1; pending = nil
        activeAuthority?.revoke()
        if clearForceEligibility { forceEligible = [] }
    }

    func prepare(records: [ProcessInventoryRecord], mode: ProcessStopMode) async throws -> ProcessStopReview {
        generation &+= 1
        activeAuthority?.revoke()
        let request = generation
        pending = nil
        guard (1...16).contains(records.count), Set(records.map(\.identity)).count == records.count,
              Set(records.map { $0.identity.pid }).count == records.count else { throw ProcessTerminationError.selectionLimit }
        if mode == .force, !Set(records.map(\.identity)).isSubset(of: forceEligible) {
            throw ProcessTerminationError.forceNotReviewed
        }
        let fresh = try await system.inspect(records.map(\.identity))
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }
        try Self.validate(records, fresh: fresh)
        let review = ProcessStopReview(id: UUID(), mode: mode, records: records.sorted { $0.identity.pid < $1.identity.pid }, createdAt: .now)
        pending = (review, now() + 60)
        return review
    }

    func execute(reviewID: UUID) async throws -> [ProcessStopResult] {
        guard let authorization = pending, authorization.review.id == reviewID else { throw ProcessTerminationError.expired }
        pending = nil // consumed before any suspension, including failures/cancel
        generation &+= 1
        let request = generation
        guard now() <= authorization.expires else { throw ProcessTerminationError.expired }
        let review = authorization.review
        let signalAuthority = ProcessSignalAuthority(deadline: authorization.expires, now: now)
        activeAuthority = signalAuthority
        defer {
            signalAuthority.revoke()
            if activeAuthority === signalAuthority { activeAuthority = nil }
        }
        let fresh = try await system.inspect(review.records.map(\.identity))
        try Task.checkCancellation()
        guard generation == request, now() <= authorization.expires else { throw ProcessTerminationError.expired }
        try Self.validate(review.records, fresh: fresh)
        var results: [ProcessStopResult] = []
        for record in review.records {
            if Task.isCancelled || generation != request || now() > authorization.expires {
                results.append(ProcessStopResult(record: record, mode: review.mode, signalSubmitted: false, presence: .unknown,
                    message: String(localized: "Cancelled or expired before sending a signal to this target.")))
                continue
            }
            do {
                try await system.signal(record, mode: review.mode, authority: signalAuthority)
                // Observe only the submitted identity. Exit is not assumed from
                // successful submission; no automatic escalation or retry.
                var presence = await system.presence(of: record.identity)
                for _ in 0..<20 {
                    guard presence == .running, !Task.isCancelled else { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    presence = await system.presence(of: record.identity)
                }
                if review.mode == .graceful, presence == .running, generation == request {
                    forceEligible.insert(record.identity)
                } else { forceEligible.remove(record.identity) }
                let message: String
                switch presence {
                case .exited: message = String(localized: "Signal submitted; the selected process identity is no longer running.")
                case .running: message = String(localized: "Signal submitted; this process is still running. Force stop requires another review and confirmation.")
                case .unknown: message = String(localized: "Signal submitted; exit could not be verified. Refresh to inspect the result.")
                }
                results.append(ProcessStopResult(record: record, mode: review.mode, signalSubmitted: true, presence: presence, message: message))
            } catch {
                forceEligible.remove(record.identity)
                results.append(ProcessStopResult(record: record, mode: review.mode, signalSubmitted: false, presence: .unknown,
                    message: String(localized: "No signal submitted: identity, protection, metadata, or operating-system permission check failed.")))
            }
        }
        return results
    }

    static func validate(_ records: [ProcessInventoryRecord], fresh: ProcessSnapshot) throws {
        guard !fresh.isPartial, fresh.records.count == records.count else { throw ProcessTerminationError.unavailable }
        for record in records {
            guard record.identity.isComplete, record.identity.executionVersion != nil,
                  record.metadataIssues.isEmpty, record.workingDirectory != nil, record.listeningPorts != nil else {
                throw ProcessTerminationError.unavailable
            }
            guard let observed = fresh.records.first(where: { $0.identity == record.identity }), observed == record else {
                throw ProcessTerminationError.changed
            }
            guard let gid = fresh.currentGID, let credentials = record.credentials,
                  credentials.isOrdinary(uid: fresh.currentUID, gid: gid) else { throw ProcessTerminationError.protectedTarget }
            guard ProcessClassifier.protectionReasons(for: observed, snapshot: fresh).isEmpty else {
                throw ProcessTerminationError.protectedTarget
            }
        }
    }
}


/// Revocation and expiry are checked at the final native sink, not only before
/// asynchronous preflight. The short lock linearizes revocation with submission;
/// it cannot retract a signal whose system call has already started.
final class ProcessSignalAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private let deadline: TimeInterval
    private let now: @Sendable () -> TimeInterval
    init(deadline: TimeInterval, now: @escaping @Sendable () -> TimeInterval) {
        self.deadline = deadline; self.now = now
    }
    func revoke() { lock.withLock { valid = false } }
    func submit<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            try Task.checkCancellation()
            guard valid, now() <= deadline else { throw ProcessTerminationError.expired }
            return try operation()
        }
    }
}
