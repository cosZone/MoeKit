import Foundation

/// Coverage of Mole's own scan scope. Even `known` is not a complete volume
/// census, an atomic filesystem snapshot, or proof of reclaimable bytes.
enum MoleScanCoverage: String, Equatable, Sendable {
    case known
    case partial
    case unavailable
    case unknown

    init(wireValue: String?) {
        switch wireValue {
        case "complete": self = .known
        case "partial": self = .partial
        case "unavailable": self = .unavailable
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .known: String(localized: "Measured within scan scope")
        case .partial: String(localized: "Partially measured")
        case .unavailable: String(localized: "Unavailable")
        case .unknown: String(localized: "Coverage unknown")
        }
    }
}

/// Preserves the wire value while preventing `unavailable + 0` from being
/// presented as an empty directory. Unknown legacy coverage retains its size
/// estimate, but must still be labeled as having unknown completeness.
struct MoleByteMeasurement: Equatable, Sendable {
    let reportedBytes: Int64
    let coverage: MoleScanCoverage

    var measuredBytes: Int64? {
        coverage == .unavailable ? nil : reportedBytes
    }

    var isLowerBound: Bool { coverage == .partial }
}

/// Read-only decoder for `mo analyze --json` in Mole V1.50.0 and V1.57.0.
/// Unknown keys are ignored by keyed decoding. No executable, filesystem, or
/// mutation behavior is attached to a report.
struct MoleAnalyzeReport: Decodable, Equatable, Sendable {
    let path: String
    let overview: Bool
    let entries: [MoleAnalyzeEntry]
    let largeFiles: [MoleLargeFile]
    let reportedBytes: Int64
    /// This is Mole's scan count, not a guaranteed census of contributing files.
    let totalFiles: Int64?
    let coverage: MoleScanCoverage

    var measurement: MoleByteMeasurement {
        MoleByteMeasurement(reportedBytes: reportedBytes, coverage: coverage)
    }

    var measuredBytes: Int64? { measurement.measuredBytes }

    /// Overview locations overlap (e.g. Home and Old Downloads), so overview
    /// proportions must never be represented as an additive disk partition.
    /// For directory views, also require known, unique, reconciled row totals
    /// with canonical absolute paths identifying direct children of `path`.
    /// These are lexical checks only: the report carries no symlink targets,
    /// inode identities, or APFS shared-extent information.
    /// This flag does not equate scan bytes with physical or reclaimable space.
    var canShowAdditivePercentages: Bool {
        guard !overview, coverage == .known, reportedBytes > 0, !entries.isEmpty,
              entries.allSatisfy({ $0.coverage == .known && !$0.insight }),
              Set(entries.map(\.id)).count == entries.count,
              let parentComponents = Self.canonicalAbsoluteComponents(path),
              entries.allSatisfy({ entry in
                  guard let childComponents = Self.canonicalAbsoluteComponents(entry.path) else { return false }
                  return childComponents.count == parentComponents.count + 1
                      && childComponents.dropLast().elementsEqual(parentComponents)
              }) else {
            return false
        }

        var sum: Int64 = 0
        for entry in entries {
            let (next, overflow) = sum.addingReportingOverflow(entry.reportedBytes)
            guard !overflow else { return false }
            sum = next
        }
        return sum == reportedBytes
    }

    /// Refuse ambiguous spellings instead of silently normalizing imported
    /// identities. This does not resolve symlinks or read the filesystem.
    private static func canonicalAbsoluteComponents(_ path: String) -> [Substring]? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        if path == "/" { return [] }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components
    }

    private enum CodingKeys: String, CodingKey {
        case path, overview, entries
        case largeFiles = "large_files"
        case reportedBytes = "total_size"
        case totalFiles = "total_files"
        case scanStatus = "scan_status"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        overview = try container.decode(Bool.self, forKey: .overview)
        entries = try container.decodeIfPresent([MoleAnalyzeEntry].self, forKey: .entries) ?? []
        largeFiles = try container.decodeIfPresent([MoleLargeFile].self, forKey: .largeFiles) ?? []
        // A path is row identity. Reject malformed duplicate rows instead of
        // silently discarding data or giving a native Table conflicting IDs.
        // An entry may also appear in large_files; only each array must be unique.
        guard Set(entries.map(\.id)).count == entries.count else {
            throw DecodingError.dataCorruptedError(forKey: .entries, in: container, debugDescription: "Duplicate entry path identities are not supported.")
        }
        guard Set(largeFiles.map(\.id)).count == largeFiles.count else {
            throw DecodingError.dataCorruptedError(forKey: .largeFiles, in: container, debugDescription: "Duplicate large-file path identities are not supported.")
        }
        reportedBytes = try container.decodeNonnegativeInt64(forKey: .reportedBytes)
        totalFiles = try container.decodeOptionalNonnegativeInt64(forKey: .totalFiles)
        coverage = MoleScanCoverage(wireValue: try container.decodeIfPresent(String.self, forKey: .scanStatus))
    }
}

struct MoleAnalyzeEntry: Decodable, Equatable, Identifiable, Sendable {
    /// Use the exact upstream path across directory and insight views. Display
    /// names and UUIDs would break selection identity when a report is reloaded.
    var id: String { path }

    let name: String
    let path: String
    let reportedBytes: Int64
    let isDirectory: Bool
    /// An insight or cleanable hint does not constitute permission to delete.
    let insight: Bool
    let cleanable: Bool
    let lastAccessTimestamp: String?
    let coverage: MoleScanCoverage

    var measurement: MoleByteMeasurement {
        MoleByteMeasurement(reportedBytes: reportedBytes, coverage: coverage)
    }

    var measuredBytes: Int64? { measurement.measuredBytes }

    /// Invalid or absent optional timestamps remain unknown, not "now".
    var lastAccess: Date? {
        guard let lastAccessTimestamp else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: lastAccessTimestamp) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: lastAccessTimestamp)
    }

    private enum CodingKeys: String, CodingKey {
        case name, path, insight, cleanable
        case reportedBytes = "size"
        case isDirectory = "is_dir"
        case lastAccessTimestamp = "last_access"
        case scanStatus = "scan_status"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        reportedBytes = try container.decodeNonnegativeInt64(forKey: .reportedBytes)
        isDirectory = try container.decode(Bool.self, forKey: .isDirectory)
        insight = try container.decodeIfPresent(Bool.self, forKey: .insight) ?? false
        cleanable = try container.decodeIfPresent(Bool.self, forKey: .cleanable) ?? false
        lastAccessTimestamp = try container.decodeIfPresent(String.self, forKey: .lastAccessTimestamp)
        coverage = MoleScanCoverage(wireValue: try container.decodeIfPresent(String.self, forKey: .scanStatus))
    }
}

/// This is a shortlist, not an exhaustive index. The wire format has no
/// per-file coverage, modification date, deletion token, or stable inode ID.
struct MoleLargeFile: Decodable, Equatable, Identifiable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let reportedBytes: Int64

    private enum CodingKeys: String, CodingKey {
        case name, path
        case reportedBytes = "size"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        reportedBytes = try container.decodeNonnegativeInt64(forKey: .reportedBytes)
    }
}

private extension KeyedDecodingContainer {
    func decodeNonnegativeInt64(forKey key: Key) throws -> Int64 {
        let value = try decode(Int64.self, forKey: key)
        guard value >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected a nonnegative integer.")
        }
        return value
    }

    func decodeOptionalNonnegativeInt64(forKey key: Key) throws -> Int64? {
        guard let value = try decodeIfPresent(Int64.self, forKey: key) else { return nil }
        guard value >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected a nonnegative integer.")
        }
        return value
    }
}
