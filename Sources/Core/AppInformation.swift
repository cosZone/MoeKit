import Foundation

/// Display-only bundle metadata. Missing build information must stay unknown.
struct AppInformation: Equatable, Sendable {
    let version: String?
    /// Human-facing release label; never derive it from Sparkle's build counter.
    let releaseVersion: String?
    let build: String?
    let copyright: String?

    var displayVersion: String? { releaseVersion ?? version }

    init(infoDictionary: [String: Any]?) {
        version = Self.displayValue(infoDictionary?["CFBundleShortVersionString"])
        releaseVersion = ReleaseVersion.installed(in: infoDictionary)?.description
        build = Self.displayValue(infoDictionary?["CFBundleVersion"])
        copyright = Self.displayValue(infoDictionary?["NSHumanReadableCopyright"])
    }

    private static func displayValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }
}

/// Public navigation only: opening a link does not submit feedback or star a repo.
enum MoeKitLinks {
    static let repository = URL(string: "https://github.com/cosZone/MoeKit")!
    static let feedback = repository.appendingPathComponent("issues")
}
