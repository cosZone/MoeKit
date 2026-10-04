import Foundation

/// MoeKit's published channels, ordered numerically rather than by tag strings,
/// release dates or unrelated GitHub workflow run numbers.
struct ReleaseVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let preview: Int?

    init?(_ string: String) {
        guard string.utf8.count <= 40 else { return nil }
        let parts = string.components(separatedBy: "-preview.")
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.number(String(core[0]), digits: 4),
              let minor = Self.number(String(core[1]), digits: 4),
              let patch = Self.number(String(core[2]), digits: 4) else { return nil }
        var preview: Int?
        if parts.count == 2 {
            guard let value = Self.number(parts[1], digits: 6) else { return nil }
            preview = value
        }
        self.major = major; self.minor = minor; self.patch = patch; self.preview = preview
    }

    private static func number(_ value: String, digits: Int) -> Int? {
        guard !value.isEmpty, value.utf8.count <= digits,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              value == "0" || !value.hasPrefix("0") else { return nil }
        return Int(value)
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return preview.map { "\(core)-preview.\($0)" } ?? core
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.preview, rhs.preview) {
        case let (.some(left), .some(right)): return left < right
        case (.some, .none): return true
        default: return false
        }
    }

    static func installed(in info: [String: Any]?) -> Self? {
        // CFBundleShortVersionString intentionally omits the preview suffix, and
        // ad-hoc/development builds do not represent an installed release.
        let raw = info?["MoeKitPreviewVersion"] as? String ?? info?["MoeKitReleaseVersion"] as? String
        return raw.flatMap(Self.init)
    }
}

struct PublishedRelease: Equatable, Sendable {
    let version: ReleaseVersion
    var pageURL: URL {
        // No URL from a network response is opened. The parsed version contains
        // only the repository's bounded canonical numeric tag alphabet.
        MoeKitLinks.repository.appendingPathComponent("releases/tag/v\(version)")
    }
}

struct GitHubReleaseRecord: Decodable, Sendable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool

    var release: PublishedRelease? {
        guard !draft, tag_name.hasPrefix("v"),
              let version = ReleaseVersion(String(tag_name.dropFirst())),
              prerelease == (version.preview != nil) else { return nil }
        return PublishedRelease(version: version)
    }
}
