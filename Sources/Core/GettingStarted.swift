import Foundation
import Observation

/// Local presentation state only. No catalog, telemetry, scan, or permission access.
@MainActor @Observable
final class GettingStartedState {
    static let currentVersion = 1
    static let preferenceKey = "gettingStarted.dismissedVersion"
    private(set) var isPresented = false
    var selectedGoal: GettingStartedGoal?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var hasConsideredAutomaticPresentation = false

    /// Production opts into UserDefaults explicitly; tests default to memory only.
    init(defaults: UserDefaults? = nil) { self.defaults = defaults }

    func presentAutomatically(hasSavedProjects: Bool, hasCatalogError: Bool, isDemo: Bool) -> Bool {
        guard !hasConsideredAutomaticPresentation else { return false }
        hasConsideredAutomaticPresentation = true
        guard !hasSavedProjects, !hasCatalogError, !isDemo,
              (defaults?.integer(forKey: Self.preferenceKey) ?? 0) < Self.currentVersion else { return false }
        return present()
    }

    @discardableResult
    func present() -> Bool {
        // Reopening an already visible window focuses it without losing its page.
        if !isPresented { selectedGoal = nil; isPresented = true }
        return true
    }

    func back() { selectedGoal = nil }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        selectedGoal = nil
        defaults?.set(Self.currentVersion, forKey: Self.preferenceKey)
    }
}

enum GettingStartedGoal: String, CaseIterable, Identifiable {
    case projects, processes, demo
    var id: Self { self }
    var symbol: String {
        switch self {
        case .projects: "folder"
        case .processes: "terminal"
        case .demo: "eye"
        }
    }
    var title: String {
        switch self {
        case .projects: String(localized: "Organize my projects")
        case .processes: String(localized: "See processes and ports")
        case .demo: String(localized: "Look around with examples")
        }
    }
    var summary: String {
        switch self {
        case .projects: String(localized: "Add a project folder or discover Git repositories in folders you choose.")
        case .processes: String(localized: "Find your current user’s processes and TCP listening ports with a read-only snapshot.")
        case .demo: String(localized: "Try example projects, task results and a Mole report before using your own data.")
        }
    }
    var firstStep: String {
        switch self {
        case .projects: String(localized: "In Projects, choose Add project for one folder, or Discover in folder to find Git repositories. Review discovery results before importing.")
        case .processes: String(localized: "In Processes & Ports, choose Start scan when you’re ready. Select a row to see its identity, ports and project-association evidence.")
        case .demo: String(localized: "Explore Projects, Tools and Tasks. The Demo banner stays visible; use Exit demo whenever you want to return to your own data.")
        }
    }
    var privacy: String {
        switch self {
        case .projects: String(localized: "Reading starts only after you choose a folder. Discovery is bounded and read-only. Project paths, names and pins are saved locally; project files are not changed.")
        case .processes: String(localized: "A snapshot is read only when you choose Start scan or Refresh: current-user executable names and paths, working directories, and TCP listening endpoints. Arguments and environment variables are not read. Scanning sends no signals; stopping requires a separate confirmation.")
        case .demo: String(localized: "Demo uses built-in examples. Entering Demo does not scan folders or processes, import reports, or replace your saved projects. Processes & Ports has no Demo scan.")
        }
    }
    var buttonTitle: String {
        switch self {
        case .projects: String(localized: "Go to Projects")
        case .processes: String(localized: "Go to Processes & Ports")
        case .demo: String(localized: "Explore demo")
        }
    }
}
