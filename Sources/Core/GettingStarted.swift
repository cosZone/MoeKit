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
        case .demo: String(localized: "Try the demo")
        }
    }
    var summary: String {
        switch self {
        case .projects: String(localized: "Add one project or find projects in a folder.")
        case .processes: String(localized: "See your running processes and listening ports.")
        case .demo: String(localized: "Explore with built-in example data.")
        }
    }
    var firstStep: String {
        switch self {
        case .projects: String(localized: "Choose Add project, or Discover in folder to find Git projects. Review the results before adding them.")
        case .processes: String(localized: "Choose Start scan in Processes & Ports. Select a process to see its details.")
        case .demo: String(localized: "Explore Projects, Tools and Tasks. Choose Exit demo to return to your own data.")
        }
    }
    var privacy: String {
        switch self {
        case .projects: String(localized: "Reading starts only after you choose a folder. Discovery is bounded and read-only. Project paths, names and pins are saved locally; project files are not changed.")
        case .processes: String(localized: "A snapshot is read only when you choose Start scan or Refresh: current-user executable names and paths, working directories, and TCP listening endpoints. Arguments and environment variables are not read. Scanning sends no signals; stopping requires a separate confirmation.")
        case .demo: String(localized: "Demo uses built-in examples. Entering Demo does not scan folders or processes, import reports, or replace your saved projects. Processes & Ports has no Demo scan.")
        }
    }
    var privacySummary: String {
        switch self {
        case .projects: String(localized: "Only folders you choose are read. Your project list is saved locally; project files stay unchanged.")
        case .processes: String(localized: "Read your processes and listening ports on demand. Stopping a process needs a separate confirmation.")
        case .demo: String(localized: "Built-in examples only. Your saved projects stay unchanged.")
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
