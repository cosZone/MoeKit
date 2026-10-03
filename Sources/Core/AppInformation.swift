import Foundation

/// Display-only bundle metadata. Missing build information must stay unknown.
struct AppInformation: Equatable, Sendable {
    let version: String?
    let build: String?
    let copyright: String?

    init(infoDictionary: [String: Any]?) {
        version = Self.displayValue(infoDictionary?["CFBundleShortVersionString"])
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
