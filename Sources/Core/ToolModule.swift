import Foundation

/// A compiled-in integration in MoeKit's personal CLI toolbox.
///
/// A module describes navigation and capabilities. It does not discover or load
/// arbitrary plug-ins, and the catalog itself never launches an executable.
protocol ToolModule: Sendable {
    var descriptor: ToolModuleDescriptor { get }
}

enum ToolReadiness: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    var canExecute: Bool {
        if case .available = self { return true }
        return false
    }

    var explanation: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

enum ToolCategory: String, CaseIterable, Sendable {
    case system
    case development
    case automation
    case productivity
    case other

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .development: String(localized: "Development")
        case .automation: String(localized: "Automation")
        case .productivity: String(localized: "Productivity")
        case .other: String(localized: "Other")
        }
    }
}

struct ToolCapabilityDescriptor: Identifiable, Equatable, Sendable {
    /// Stable, namespaced identity; never derived from a translated title.
    let id: String
    let title: String
    let summary: String
    let systemImage: String
    let readiness: ToolReadiness
}

struct ToolModuleDescriptor: Identifiable, Equatable, Sendable {
    /// Stable identity suitable for selection and persisted routes.
    let id: String
    let title: String
    let summary: String
    let systemImage: String
    let category: ToolCategory
    let keywords: [String]
    let readiness: ToolReadiness
    let capabilities: [ToolCapabilityDescriptor]
}

enum ToolModuleRegistryError: Error, Equatable {
    case duplicateModuleID(String)
    case duplicateCapabilityID(String)
}

/// New first-party CLI integrations register here without changing global
/// Projects / Tools / Tasks navigation. This is intentionally not a plug-in host.
struct ToolModuleRegistry: Sendable {
    let modules: [any ToolModule]

    init() {
        modules = [MoleModule()]
    }

    /// Explicit injection supports other built-in modules and deterministic tests.
    init(modules: [any ToolModule]) throws {
        var moduleIDs: Set<String> = []
        var capabilityIDs: Set<String> = []
        for module in modules {
            let descriptor = module.descriptor
            guard moduleIDs.insert(descriptor.id).inserted else {
                throw ToolModuleRegistryError.duplicateModuleID(descriptor.id)
            }
            for capability in descriptor.capabilities {
                guard capabilityIDs.insert(capability.id).inserted else {
                    throw ToolModuleRegistryError.duplicateCapabilityID(capability.id)
                }
            }
        }
        self.modules = modules
    }

    static var builtIn: ToolModuleRegistry { ToolModuleRegistry() }

    var descriptors: [ToolModuleDescriptor] {
        modules.map(\.descriptor)
    }

    func module(id: String) -> (any ToolModule)? {
        modules.first { $0.descriptor.id == id }
    }

    func descriptor(id: String) -> ToolModuleDescriptor? {
        module(id: id)?.descriptor
    }

    /// All search words must match some part of the module's localized catalog.
    /// Registry order is preserved, including for an empty search.
    func search(_ query: String) -> [ToolModuleDescriptor] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return descriptors }

        return descriptors.filter { descriptor in
            let fields = [descriptor.id, descriptor.title, descriptor.summary, descriptor.category.title]
                + descriptor.keywords
                + descriptor.capabilities.flatMap { [$0.id, $0.title, $0.summary] }
            return terms.allSatisfy { term in
                fields.contains { $0.localizedStandardContains(term) }
            }
        }
    }
}

enum MoleCapability: String, CaseIterable, Identifiable, Sendable {
    case space
    case clean
    case apps
    case maintenance
    case status

    var id: String { "mole.\(rawValue)" }

    var title: String {
        switch self {
        case .space: String(localized: "Space")
        case .clean: String(localized: "Clean")
        case .apps: String(localized: "Apps")
        case .maintenance: String(localized: "Maintenance")
        case .status: String(localized: "Status")
        }
    }

    var systemImage: String {
        switch self {
        case .space: "internaldrive"
        case .clean: "sparkles"
        case .apps: "square.grid.2x2"
        case .maintenance: "wrench.and.screwdriver"
        case .status: "waveform.path.ecg"
        }
    }

    var summary: String {
        switch self {
        case .space:
            String(localized: "Inspect directory sizes, large files, and scan coverage.")
        case .clean:
            String(localized: "Review caches, project artifacts, and installers.")
        case .apps:
            String(localized: "Review installed apps and their related files.")
        case .maintenance:
            String(localized: "Understand maintenance tasks and their effects.")
        case .status:
            String(localized: "Inspect system metrics and their freshness.")
        }
    }

    var readiness: ToolReadiness {
        .unavailable(reason: String(localized: "Mole execution is not connected in this milestone."))
    }

    var descriptor: ToolCapabilityDescriptor {
        ToolCapabilityDescriptor(
            id: id,
            title: title,
            summary: summary,
            systemImage: systemImage,
            readiness: readiness
        )
    }
}

struct MoleModule: ToolModule {
    static let id = "mole"

    var descriptor: ToolModuleDescriptor {
        ToolModuleDescriptor(
            id: Self.id,
            title: String(localized: "Mole"),
            summary: String(localized: "A native workspace for disk analysis, cleanup, apps, maintenance, and status."),
            systemImage: "internaldrive",
            category: .system,
            keywords: ["mo", "CLI", "disk", "storage", "analyze", "cleanup", "uninstall", "optimize", "磁盘", "空间", "清理", "应用", "维护", "状态"],
            readiness: .unavailable(reason: String(localized: "Mole execution is not connected in this milestone.")),
            capabilities: MoleCapability.allCases.map(\.descriptor)
        )
    }
}
