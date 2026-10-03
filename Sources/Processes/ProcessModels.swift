import Foundation

/// PID is not an identity. Preserve the kernel's full start timestamp and the
/// executable observed with it. These fields still do not prove ownership or
/// detect a same-path re-exec; a future executor needs stronger evidence.
struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startSeconds: UInt64?
    let startMicroseconds: UInt64?
    let uid: UInt32?
    let executablePath: String?

    var isComplete: Bool {
        pid > 1 && startSeconds.map { $0 > 0 } == true
            && startMicroseconds.map { $0 < 1_000_000 } == true
            && uid != nil && executablePath.map(ProcessPath.isCanonicalAbsolute) == true
    }
    var startedAt: Date? {
        guard let seconds = startSeconds, let microseconds = startMicroseconds,
              seconds > 0, microseconds < 1_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(microseconds) / 1_000_000)
    }
}

struct ListeningPort: Hashable, Sendable {
    let port: UInt16
    let address: String
    let transport: String
}

struct ProcessInventoryRecord: Identifiable, Hashable, Sendable {
    let identity: ProcessIdentity
    let name: String
    let parentPID: Int32?
    let processGroupID: Int32?
    /// Canonical path resolved by the provider, never read on the main actor.
    let workingDirectory: String?
    /// nil means unavailable/incomplete. An empty array means no TCP listeners
    /// were observed during a complete descriptor read, not no network activity.
    let listeningPorts: [ListeningPort]?
    var metadataIssues: [String] = []
    var id: ProcessIdentity { identity }
}

struct ProcessSnapshot: Sendable {
    var id = UUID()
    var capturedAt: Date = .now
    let records: [ProcessInventoryRecord]
    let currentUID: UInt32
    let observerPID: Int32
    var issues: [String] = []
    var isPartial = false
}

struct ProcessScanOptions: Sendable {
    var maximumProcesses = 4_096
    var maximumFileDescriptorsPerProcess = 256
    var maximumDuration: TimeInterval = 5
}

protocol ProcessInventoryProviding: Sendable {
    func scan(options: ProcessScanOptions) async throws -> ProcessSnapshot
}

struct ProcessProjectScope: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let canonicalPath: String
}

enum ProcessAssociation: Hashable, Sendable {
    /// Reserved for a future launch ledger. Discovery never emits this case.
    case managed(sessionID: UUID)
    case inferred(projectID: UUID, projectName: String, evidence: String)
    case unknown

    var title: String {
        switch self {
        case .managed: String(localized: "Started by MoeKit")
        case .inferred: String(localized: "Observed association")
        case .unknown: String(localized: "Unattributed")
        }
    }
    var projectID: UUID? {
        if case let .inferred(id, _, _) = self { return id }
        return nil
    }
    var projectName: String? {
        if case let .inferred(_, name, _) = self { return name }
        return nil
    }
    var evidence: String {
        switch self {
        case .managed: String(localized: "A matching MoeKit launch record is required.")
        case let .inferred(_, _, evidence): evidence
        case .unknown: String(localized: "No project association was established from readable metadata.")
        }
    }
}

/// Explanation is kept separate from the association so an unreadable path,
/// an unmatched path, and ambiguous catalog aliases never look equivalent.
struct ProcessAssociationAssessment: Hashable, Sendable {
    let association: ProcessAssociation
    let explanation: String
    let canonicalProjectPath: String?
}

enum ProcessPortFilter: String, CaseIterable, Identifiable, Sendable {
    case all, listening, unknown
    var id: Self { self }
    var title: String {
        switch self {
        case .all: String(localized: "All processes")
        case .listening: String(localized: "TCP listeners")
        case .unknown: String(localized: "Unknown ports")
        }
    }
    func includes(_ record: ProcessInventoryRecord) -> Bool {
        switch self {
        case .all: true
        case .listening: record.listeningPorts.map { !$0.isEmpty } == true
        case .unknown: record.listeningPorts == nil
        }
    }
}

enum ProcessPath {
    static func isCanonicalAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("//"),
              path == "/" || !path.hasSuffix("/") else { return false }
        return !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }
    /// Component boundary prevents /work/app from matching /work/application.
    static func contains(_ path: String, in root: String) -> Bool {
        guard root != "/", isCanonicalAbsolute(root), isCanonicalAbsolute(path) else { return false }
        return path == root || path.hasPrefix(root + "/")
    }
}

enum ProcessClassifier {
    static func association(for record: ProcessInventoryRecord, projects: [ProcessProjectScope]) -> ProcessAssociation {
        assessment(for: record, projects: projects).association
    }

    static func assessment(for record: ProcessInventoryRecord, projects: [ProcessProjectScope]) -> ProcessAssociationAssessment {
        guard let cwd = record.workingDirectory, ProcessPath.isCanonicalAbsolute(cwd) else {
            return ProcessAssociationAssessment(association: .unknown,
                explanation: String(localized: "Working directory is unavailable or unresolved. Names, ports and parent processes do not establish a project association."),
                canonicalProjectPath: nil)
        }
        let usableProjects = projects.filter { $0.canonicalPath != "/" && ProcessPath.isCanonicalAbsolute($0.canonicalPath) }
        guard !usableProjects.isEmpty else {
            return ProcessAssociationAssessment(association: .unknown,
                explanation: String(localized: "No readable project folders were available for this scan. Add a project, then refresh to compare its folder."),
                canonicalProjectPath: nil)
        }
        let matches = usableProjects.filter { ProcessPath.contains(cwd, in: $0.canonicalPath) }
        guard let deepest = matches.max(by: { $0.canonicalPath.count < $1.canonicalPath.count }) else {
            return ProcessAssociationAssessment(association: .unknown,
                explanation: String(localized: "The observed working directory is outside the project folders resolved for this snapshot."),
                canonicalProjectPath: nil)
        }
        // Aliased catalog entries with the same canonical root are ambiguous.
        guard matches.filter({ $0.canonicalPath == deepest.canonicalPath }).count == 1 else {
            return ProcessAssociationAssessment(association: .unknown,
                explanation: String(localized: "Multiple catalog projects resolve to the same matching folder. No project was chosen."),
                canonicalProjectPath: nil)
        }
        let explanation = String(localized: "Observed working directory is inside this project's canonical folder. This is an association, not ownership.")
        return ProcessAssociationAssessment(
            association: .inferred(projectID: deepest.id, projectName: deepest.name, evidence: explanation),
            explanation: explanation, canonicalProjectPath: deepest.canonicalPath)
    }

    static func protectionReasons(for record: ProcessInventoryRecord, snapshot: ProcessSnapshot) -> [String] {
        var reasons: [String] = []
        if record.identity.pid <= 1 || record.identity.pid == snapshot.observerPID {
            reasons.append(String(localized: "System process or MoeKit itself."))
        }
        if record.identity.uid != snapshot.currentUID {
            reasons.append(String(localized: "The process owner is different or unknown."))
        }
        if !record.identity.isComplete {
            reasons.append(String(localized: "Process identity is incomplete."))
        }
        if record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.append(String(localized: "Process name is unavailable."))
        }
        if let startedAt = record.identity.startedAt, startedAt > snapshot.capturedAt {
            reasons.append(String(localized: "Process start time is inconsistent with this snapshot."))
        }
        let path = record.identity.executablePath?.lowercased() ?? ""
        let name = record.name.lowercased()
        let binary = (path as NSString).lastPathComponent
        // Deliberately conservative hints, not an exhaustive safety guarantee.
        // Never infer that a matching browser is an isolated automation instance.
        let guardedNames = ["chrome", "chromium", "safari", "firefox", "webkit", "brave", "msedge", "browser",
                            "xcode", "code helper", "electron", "idea", "pycharm", "webstorm", "cursor", "zed",
                            "docker", "containerd", "podman", "qemu", "virtualbox", "vmware", "parallels", "colima",
                            "postgres", "mysqld", "mariadbd", "mongod", "redis", "sqlite", "ollama"]
        if path.contains(".app/") || guardedNames.contains(where: { name.contains($0) || binary.contains($0) }) {
            reasons.append(String(localized: "Application, browser, IDE, database, VM, or shared-service hint. Review individually."))
        }
        if ["launchd", "sshd", "WindowServer", "loginwindow", "kernel_task", "bash", "zsh", "sh", "fish", "tmux", "screen"].map({ $0.lowercased() }).contains(binary.isEmpty ? name : binary) {
            reasons.append(String(localized: "System service or shared shell. Review individually."))
        }
        return reasons
    }
}

struct StopPlanTarget: Identifiable, Sendable {
    let record: ProcessInventoryRecord
    let association: ProcessAssociation
    let associationEvidence: String
    let canonicalProjectPath: String?
    let protectionReasons: [String]
    let risks: [String]
    var identity: ProcessIdentity { record.identity }
    var name: String { record.name }
    var id: ProcessIdentity { identity }
}

/// Inspection only. No signal number, group target, executable command or
/// execution closure is stored in this model; no executor exists in this build.
struct StopPlan: Identifiable, Sendable {
    let id: UUID
    let snapshotID: UUID
    let snapshotDate: Date
    let createdAt: Date
    let currentUID: UInt32
    let observerPID: Int32
    let selectedIdentities: Set<ProcessIdentity>
    let targets: [StopPlanTarget]
    let warnings: [String]
    var canExecute: Bool { false }
    var protectedTargetCount: Int { targets.filter { !$0.protectionReasons.isEmpty }.count }
}

enum StopPlanInvalidation: Hashable, Sendable {
    case emptySelection, selectionChanged, staleSnapshot, snapshotFromFuture, partialSnapshot
    case missingTarget(ProcessIdentity), identityChanged(Int32), incompleteIdentity(ProcessIdentity)
    case metadataChanged(ProcessIdentity), invalidStartTime(ProcessIdentity), safetyContextChanged
}

enum ProcessStopPlanner {
    static let maximumSnapshotAge: TimeInterval = 15

    static func makePlan(snapshot: ProcessSnapshot, selection: Set<ProcessIdentity>, projects: [ProcessProjectScope], now: Date = .now) -> StopPlan {
        let targets = snapshot.records.filter { selection.contains($0.identity) }.sorted { $0.identity.pid < $1.identity.pid }.map { record in
            let assessment = ProcessClassifier.assessment(for: record, projects: projects)
            let association = assessment.association
            let protectionReasons = ProcessClassifier.protectionReasons(for: record, snapshot: snapshot)
            var risks = protectionReasons
            if association.projectID == nil {
                risks.append(String(localized: "No project ownership was established."))
            }
            if let parent = record.parentPID, parent == 1 || !snapshot.records.contains(where: { $0.identity.pid == parent }) {
                risks.append(String(localized: "Parent is unavailable or reparented. This does not mean the process is abandoned."))
            }
            if let group = record.processGroupID, group > 0,
               snapshot.records.contains(where: { $0.processGroupID == group && !selection.contains($0.identity) }) {
                risks.append(String(localized: "The observed process group includes unselected processes. No group action is planned."))
            }
            if !record.metadataIssues.isEmpty || record.workingDirectory == nil || record.listeningPorts == nil {
                risks.append(String(localized: "Some metadata is unavailable or incomplete."))
            }
            return StopPlanTarget(record: record, association: association, associationEvidence: assessment.explanation,
                                  canonicalProjectPath: assessment.canonicalProjectPath,
                                  protectionReasons: protectionReasons, risks: risks)
        }
        var warnings = [String(localized: "Preview only. Stopping and force stopping are not implemented."),
                        String(localized: "Only exact selected identities are listed. Parents, children and process groups are not added automatically."),
                        String(localized: "A future stop must re-read identities and prefer cooperative shutdown. A submitted signal would not prove exit.")]
        if snapshot.isPartial { warnings.append(String(localized: "This is a partial snapshot; unseen processes or dependencies may exist.")) }
        if snapshot.capturedAt > now || now.timeIntervalSince(snapshot.capturedAt) > maximumSnapshotAge {
            warnings.append(String(localized: "This snapshot is stale or has an invalid timestamp. Refresh before reviewing a future action."))
        }
        if targets.count != selection.count { warnings.append(String(localized: "Some selected identities are no longer in this snapshot.")) }
        return StopPlan(id: UUID(), snapshotID: snapshot.id, snapshotDate: snapshot.capturedAt, createdAt: now,
                        currentUID: snapshot.currentUID, observerPID: snapshot.observerPID,
                        selectedIdentities: selection, targets: targets, warnings: warnings)
    }

    /// Pure future-executor prerequisite, not permission to act. A successful
    /// comparison cannot make a later PID-based signal atomic or guarantee safety.
    static func invalidations(for plan: StopPlan, snapshot: ProcessSnapshot, selection: Set<ProcessIdentity>, now: Date = .now) -> Set<StopPlanInvalidation> {
        var result: Set<StopPlanInvalidation> = []
        if selection.isEmpty { result.insert(.emptySelection) }
        if selection != plan.selectedIdentities { result.insert(.selectionChanged) }
        if snapshot.capturedAt > now { result.insert(.snapshotFromFuture) }
        if now.timeIntervalSince(snapshot.capturedAt) > maximumSnapshotAge { result.insert(.staleSnapshot) }
        if snapshot.isPartial { result.insert(.partialSnapshot) }
        if snapshot.currentUID != plan.currentUID || snapshot.observerPID != plan.observerPID { result.insert(.safetyContextChanged) }
        for identity in plan.selectedIdentities {
            guard identity.isComplete else { result.insert(.incompleteIdentity(identity)); continue }
            if identity.startedAt.map({ $0 > snapshot.capturedAt }) == true { result.insert(.invalidStartTime(identity)) }
            guard let fresh = snapshot.records.first(where: { $0.identity == identity }) else {
                result.insert(snapshot.records.contains(where: { $0.identity.pid == identity.pid }) ? .identityChanged(identity.pid) : .missingTarget(identity))
                continue
            }
            guard let original = plan.targets.first(where: { $0.identity == identity }) else {
                result.insert(.missingTarget(identity)); continue
            }
            if original.record != fresh { result.insert(.metadataChanged(identity)) }
        }
        return result
    }
}
