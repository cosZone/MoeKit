import Foundation

/// Counts from one complete porcelain-v2/NUL observation. Conflicted paths are
/// counted separately, not counted again as staged/unstaged. A path with both
/// index and worktree edits contributes to both edit counts but only one total.
struct GitStatusSummary: Hashable, Sendable {
    let branch: String?
    let isUnborn: Bool
    let upstream: String?
    let ahead: Int?
    let behind: Int?
    let stagedCount: Int
    let unstagedCount: Int
    let untrackedCount: Int
    let conflictCount: Int
    let changedPathCount: Int

    var hasReportedChanges: Bool { changedPathCount > 0 }
}

/// Session-only evidence. It is deliberately not a ProjectRecord field or
/// persisted catalog property: reopening a project must not revive old status.
struct GitStatusSnapshot: Hashable, Sendable {
    let observedAt: Date
    let summary: GitStatusSummary
}

/// Explicit absence/failure cannot be mistaken for a successful empty result.
/// No case grants deletion eligibility or proves that anything was pushed.
enum GitStatusState: Equatable, Sendable {
    case notChecked
    case unavailable(GitStatusUnavailableReason)
    case observed(GitStatusSnapshot)

    var snapshot: GitStatusSnapshot? {
        guard case let .observed(snapshot) = self else { return nil }
        return snapshot
    }
}

enum GitStatusUnavailableReason: Equatable, Sendable {
    case executionDisabled, unsupportedGit, unsupportedRepository
    case repositoryChanged, commandFailed, invalidOutput, outputLimit, timedOut, cancelled
}

enum GitStatusParseError: Error, Equatable {
    case oversized, malformed, incomplete
}

/// Byte-oriented: filenames may contain newlines, spaces, or invalid UTF-8.
/// They are never decoded, executed, normalized, or persisted by this parser.
enum GitStatusParser {
    static let maximumBytes = 2 * 1_024 * 1_024

    static func parse(_ data: Data) throws -> GitStatusSummary {
        guard data.count <= maximumBytes else { throw GitStatusParseError.oversized }
        guard !data.isEmpty, data.last == 0 else { throw GitStatusParseError.incomplete }
        var headers: [String: String] = [:]
        var staged = 0, unstaged = 0, untracked = 0, conflicts = 0, total = 0
        var needsOriginalPath = false
        var paths = Set<Data>()
        var objectIDWidths = Set<Int>()
        var cursor = data.startIndex
        while cursor < data.endIndex {
            guard let end = data[cursor...].firstIndex(of: 0) else { throw GitStatusParseError.incomplete }
            let record = data[cursor..<end]
            cursor = data.index(after: end)
            guard !record.isEmpty else { throw GitStatusParseError.malformed }
            if needsOriginalPath { needsOriginalPath = false; continue }
            if record.starts(with: [35, 32]) {
                // Unknown headers may use a future syntax; ignore them as the
                // porcelain-v2 contract requires, without interpreting payload.
                let body = record.dropFirst(2)
                let boundary = body.firstIndex(of: 32) ?? body.endIndex
                let key = String(decoding: body[..<boundary], as: UTF8.self)
                if ["branch.oid", "branch.head", "branch.upstream", "branch.ab"].contains(key) {
                    guard boundary < body.endIndex,
                          let value = String(data: Data(body[body.index(after: boundary)...]), encoding: .utf8) else {
                        throw GitStatusParseError.malformed
                    }
                    guard headers[key] == nil, !value.isEmpty,
                          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        throw GitStatusParseError.malformed
                    }
                    headers[key] = value
                }
                continue // Unknown headers are extensible in the Git format.
            }
            switch record.first {
            case 49, 50: // ordinary or rename/copy
                let renamed = record.first == 50
                let fields = record.split(separator: 32, maxSplits: renamed ? 9 : 8, omittingEmptySubsequences: false)
                guard fields.count == (renamed ? 10 : 9), fields[0].count == 1, fields.allSatisfy({ !$0.isEmpty }),
                      validXY(fields[1], renamed: renamed), validSubmodule(fields[2]),
                      fields[3...5].allSatisfy(validMode), fields[6...7].allSatisfy(validObjectID) else {
                    throw GitStatusParseError.malformed
                }
                if renamed {
                    let score = fields[8]
                    guard let kind = score.first, [82, 67].contains(kind), let value = Int(String(decoding: score.dropFirst(), as: UTF8.self)),
                          (0...100).contains(value), score.dropFirst().allSatisfy({ (48...57).contains($0) }) else {
                        throw GitStatusParseError.malformed
                    }
                    guard fields[1].contains(kind) else { throw GitStatusParseError.malformed }
                    needsOriginalPath = true
                }
                objectIDWidths.formUnion(fields[6...7].map(\.count))
                guard paths.insert(Data(fields[renamed ? 9 : 8])).inserted else { throw GitStatusParseError.malformed }
                if fields[1].first != 46 { staged += 1 }
                if fields[1].last != 46 { unstaged += 1 }
                total += 1
            case 117: // unmerged
                let fields = record.split(separator: 32, maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11, fields[0].count == 1, fields.allSatisfy({ !$0.isEmpty }),
                      ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(String(decoding: fields[1], as: UTF8.self)),
                      validSubmodule(fields[2]), fields[3...6].allSatisfy(validMode),
                      fields[7...9].allSatisfy(validObjectID) else { throw GitStatusParseError.malformed }
                objectIDWidths.formUnion(fields[7...9].map(\.count))
                guard paths.insert(Data(fields[10])).inserted else { throw GitStatusParseError.malformed }
                conflicts += 1; total += 1
            case 63: // untracked: -uall gives one record per file, not collapsed directories
                guard record.count > 2, record[record.index(after: record.startIndex)] == 32 else {
                    throw GitStatusParseError.malformed
                }
                guard paths.insert(Data(record.dropFirst(2))).inserted else { throw GitStatusParseError.malformed }
                untracked += 1; total += 1
            default: throw GitStatusParseError.malformed // Ignored/unknown records are not in our query contract.
            }
        }
        guard !needsOriginalPath else { throw GitStatusParseError.incomplete }
        guard let oid = headers["branch.oid"], let head = headers["branch.head"],
              oid == "(initial)" || validObjectID(Data(oid.utf8)[...]) else { throw GitStatusParseError.incomplete }
        if oid != "(initial)" { objectIDWidths.insert(oid.utf8.count) }
        guard objectIDWidths.count <= 1, head == "(detached)" || validReferenceName(head),
              !(oid == "(initial)" && head == "(detached)") else { throw GitStatusParseError.malformed }
        if let upstream = headers["branch.upstream"] {
            guard head != "(detached)", validReferenceName(upstream) else { throw GitStatusParseError.malformed }
        }
        var ahead: Int?, behind: Int?
        if let comparison = headers["branch.ab"] {
            guard oid != "(initial)", head != "(detached)" else { throw GitStatusParseError.malformed }
            let parts = comparison.split(separator: " ", omittingEmptySubsequences: false)
            guard headers["branch.upstream"] != nil, parts.count == 2,
                  parts[0].first == "+", parts[1].first == "-",
                  let a = unsignedCount(parts[0].dropFirst()), let b = unsignedCount(parts[1].dropFirst()) else {
                throw GitStatusParseError.malformed
            }
            ahead = a; behind = b
        }
        return GitStatusSummary(branch: head == "(detached)" ? nil : head, isUnborn: oid == "(initial)",
            upstream: headers["branch.upstream"], ahead: ahead, behind: behind,
            stagedCount: staged, unstagedCount: unstaged, untrackedCount: untracked,
            conflictCount: conflicts, changedPathCount: total)
    }

    // Branch headers are displayable reference names, never commands or paths.
    private static func validReferenceName(_ value: String) -> Bool {
        !value.isEmpty && value != "@" && !value.contains("..") && !value.contains("@{") &&
            !value.hasPrefix("/") && !value.hasSuffix("/") && !value.hasSuffix(".") &&
            !value.contains("//") && !value.utf8.contains(where: { $0 <= 32 || $0 == 127 || [126, 94, 58, 63, 42, 91, 92].contains($0) }) &&
            value.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }
    private static func unsignedCount(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(value)
    }
    private static func validMode(_ value: Data.SubSequence) -> Bool {
        value.count == 6 && value.allSatisfy { (48...55).contains($0) }
    }
    private static func validObjectID(_ value: Data.SubSequence) -> Bool {
        [40, 64].contains(value.count) && value.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validSubmodule(_ value: Data.SubSequence) -> Bool {
        let bytes = Array(value)
        return bytes == Array("N...".utf8) || (bytes.count == 4 && bytes[0] == 83 &&
            [46, 67].contains(bytes[1]) && [46, 77].contains(bytes[2]) && [46, 85].contains(bytes[3]))
    }
    private static func validXY(_ value: Data.SubSequence, renamed: Bool) -> Bool {
        let bytes = Array(value)
        let allowed: [UInt8] = renamed ? [46, 77, 84, 65, 68, 82, 67] : [46, 77, 84, 65, 68]
        return bytes.count == 2 && bytes != [46, 46] && bytes.allSatisfy(allowed.contains) &&
            (!renamed || bytes.contains(82) || bytes.contains(67))
    }
}
