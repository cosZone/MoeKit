import Foundation
import Observation

/// A read-only summary. It never starts work or treats disappearance of busy
/// state as success. Completed/partial/failed come only from a real task record.
enum MenuBarActivity: String, CaseIterable, Sendable {
    case idle, busy, completed, attention, cancelled, demo

    var title: String {
        switch self {
        case .idle: MenuBarText.localized("Ready")
        case .busy: MenuBarText.localized("Working")
        case .completed: MenuBarText.localized("Latest task completed")
        case .attention: MenuBarText.localized("Needs attention")
        case .cancelled: MenuBarText.localized("Latest task cancelled")
        case .demo: MenuBarText.localized("Demo")
        }
    }
    var symbol: String {
        switch self {
        case .idle: "tray"
        case .busy: "clock"
        case .completed: "checkmark.circle"
        case .attention: "exclamationmark.circle"
        case .cancelled: "stop.circle"
        case .demo: "eye"
        }
    }
}

enum MenuBarText {
    static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "MenuBar")
    }
}

struct MenuBarSnapshot: Equatable, Sendable {
    var activity: MenuBarActivity = .idle
    var taskTitle: String?

    var detail: String {
        if let taskTitle, !taskTitle.isEmpty { return taskTitle }
        return MenuBarText.localized(activity == .demo ? "Example workspace" : "Open MoeKit for details")
    }

    static func summarize(tasks: [TaskRecord], isDemo: Bool, isBusy: Bool, hasIssue: Bool) -> Self {
        guard !isDemo else { return .init(activity: .demo) }
        let real = tasks.filter { !$0.isDemo }
        if let running = real.filter({ $0.status == .running }).max(by: { $0.startedAt < $1.startedAt }) {
            return .init(activity: .busy, taskTitle: running.title)
        }
        if isBusy { return .init(activity: .busy) }
        if hasIssue { return .init(activity: .attention) }
        guard let latest = real.max(by: { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }) else { return .init() }
        switch latest.status {
        case .completed: return .init(activity: .completed, taskTitle: latest.title)
        case .failed, .partial: return .init(activity: .attention, taskTitle: latest.title)
        case .cancelled: return .init(activity: .cancelled, taskTitle: latest.title)
        case .running: return .init(activity: .busy, taskTitle: latest.title)
        }
    }
}

@MainActor @Observable
final class MenuBarPresentation {
    var snapshot = MenuBarSnapshot()
    var canCheckUpdates = true
}

@MainActor
extension WorkspaceStore {
    /// Observe existing app-owned models only. In particular, this does not read
    /// paths, scan processes, discover tools, refresh usage or create journals.
    var menuBarSnapshot: MenuBarSnapshot {
        let busy = [isScanning, isImporting, processes.isScanning,
                    processes.termination.isBusy, moleAnalysis.isBusy,
                    installerTrash.isBusy, gitCleanup.isBusy, gitWorktreeFinish.isBusy,
                    gitWorktreeFinish.remotePush.isBusy, trash.isBusy,
                    dockerCleanup.isBusy, cleanup.isBusy, toolPreparation.isInspecting].contains(true)
        let transientIssue = [gitWorktreeFinish.error, gitWorktreeFinish.lastOperationError,
                     gitWorktreeFinish.remotePush.error, cleanup.errorMessage, cleanup.lastMutationError,
                     trash.lastMutationError, installerTrash.lastMutationError, errorMessage, processes.errorMessage, processes.termination.errorMessage,
                     moleAnalysis.errorMessage, installerTrash.errorMessage, gitCleanup.error,
                     trash.errorMessage, dockerCleanup.errorMessage, toolPreparation.errorMessage]
            .contains { $0 != nil }
        let outcomeIssue = [MenuBarOutcomeEvidence.needsAttention(cleanup.lastOutcome),
                            MenuBarOutcomeEvidence.needsAttention(trash.lastOutcome),
                            MenuBarOutcomeEvidence.needsAttention(installerTrash.lastOutcome),
                            MenuBarOutcomeEvidence.needsAttention(dockerCleanup.result),
                            processes.termination.results.contains { $0.presence != .exited },
                            gitWorktreeFinish.remotePush.lastResult.map { !$0.verified } ?? false,
                            moleAnalysis.result.map { $0.report.coverage != .known } ?? false].contains(true)
        return .summarize(tasks: tasks, isDemo: isDemoEnabled, isBusy: busy, hasIssue: transientIssue || outcomeIssue)
    }
}

/// Pure outcome classification; partial, retained, cancelled and unknown
/// mutations can never turn an older successful scan into an all-clear badge.
enum MenuBarOutcomeEvidence {
    static func needsAttention(_ outcome: CleanupOutcome?) -> Bool {
        outcome?.items.contains { !$0.succeeded || $0.requiresRecovery } ?? false
    }
    static func needsAttention(_ outcome: TrashOutcome?) -> Bool {
        outcome?.items.contains { $0.status != .deleted } ?? false
    }
    static func needsAttention(_ outcome: InstallerTrashOutcome?) -> Bool {
        guard let outcome else { return false }
        return outcome.requiresRecovery || (!outcome.movedToTrash && outcome.receipt?.state != .restored)
    }
    static func needsAttention(_ outcome: DockerCleanupResult?) -> Bool {
        guard let outcome else { return false }
        return outcome.cancelled || outcome.hasUncertainty || outcome.items.contains { $0.state != .removed }
    }
}
