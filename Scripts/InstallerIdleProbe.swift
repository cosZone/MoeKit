import Darwin
import Dispatch
import Foundation
import OpenDirectory

/// Standalone, opt-in hosted-CI acceptance probe. Compile this file together
/// with the unchanged production InstallerUseEvidence.swift, without AppKit,
/// XCTest, an app launch, or xcodebuild. Never inject or filter its inventory.
@main
enum InstallerIdleProbe {
    static func main() async {
        do {
            let env = ProcessInfo.processInfo.environment
            guard env["MOEKIT_INSTALLER_IDLE_PROBE"] == "1",
                  env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
                  let sha = env["MOEKIT_INSTALLER_SOURCE_SHA"], sha.count == 40,
                  sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let temporaryPath = env["RUNNER_TEMP"], let evidencePath = env["MOEKIT_INSTALLER_EVIDENCE_DIR"] else {
                throw ProbeFailure("The standalone probe requires explicit hosted-CI and exact-source evidence configuration.")
            }
            let evidence = try ProbeDirectory.open(URL(fileURLWithPath: evidencePath, isDirectory: true))
            try evidence.requirePrivate()
            let temporary = try ProbeDirectory.open(physicalURL(temporaryPath))
            let fixture = try ProbeFixture(parent: temporary)
            do {
                try fixture.validate()
                let target = InstallerUseTarget(device: fixture.initial.device, inode: fixture.initial.inode,
                    path: fixture.fileURL.path, observerRetainedFileDescriptors: [fixture.fd])
                await printHandleStageDiagnostics(fixture: fixture, target: target)
                let deadline = ProcessInfo.processInfo.systemUptime + 25
                var latest = "No complete observation finished."
                var hadOtherUnavailable = false
                var duplicate = fcntl(fixture.fd, F_DUPFD_CLOEXEC, 0)
                guard duplicate >= 0 else { throw ProbeFailure("The owned positive-control descriptor could not be duplicated.") }
                defer { if duplicate >= 0 { close(duplicate) } }
                var observed = false
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try fixture.validate()
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { break }
                    let provider = NativeInstallerUseEvidenceProvider(maximumDuration: min(8, remaining))
                    let fullEvidence = await provider.evidence(for: target)
                    switch fullEvidence {
                    case .observedUse: observed = true
                    case .noUseObserved: throw ProbeFailure("The actual provider missed the unexcluded owned duplicate descriptor.")
                    case .unavailable(let reason):
                        if !hadOtherUnavailable, env["MOEKIT_INSTALLER_CONDITIONAL_IDLE"] == "1",
                           fullEvidence == .unavailable(reason: InstallerUseEvidence.attachedImageLimitation) {
                            close(duplicate); duplicate = -1
                            try await recordUnsupportedEnvironment(fixture: fixture, target: target, directory: evidence,
                                                                   sha: sha, fullEvidence: fullEvidence)
                            exit(3) // Distinct unsupported status; never full current eligibility.
                        }
                        latest = reason
                        hadOtherUnavailable = true
                    }
                    try fixture.validate()
                    if observed { break }
                    if ProcessInfo.processInfo.systemUptime + 0.2 < deadline { try await Task.sleep(for: .milliseconds(200)) }
                }
                close(duplicate); duplicate = -1
                guard observed else {
                    throw ProbeFailure("The actual provider could not observe the owned positive-control descriptor. Last cause: \(latest)")
                }
                var accepted = false
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try fixture.validate()
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { break }
                    let provider = NativeInstallerUseEvidenceProvider(maximumDuration: min(8, remaining))
                    let fullEvidence = await provider.evidence(for: target)
                    switch fullEvidence {
                    case .noUseObserved: accepted = true
                    case .observedUse(let reason): throw ProbeFailure("Unexpected use of the owned fixture: \(reason)")
                    case .unavailable(let reason):
                        if !hadOtherUnavailable, env["MOEKIT_INSTALLER_CONDITIONAL_IDLE"] == "1",
                           fullEvidence == .unavailable(reason: InstallerUseEvidence.attachedImageLimitation) {
                            try await recordUnsupportedEnvironment(fixture: fixture, target: target, directory: evidence,
                                                                   sha: sha, fullEvidence: fullEvidence)
                            exit(3)
                        }
                        latest = reason
                        hadOtherUnavailable = true
                    }
                    try fixture.validate()
                    if accepted { break }
                    if ProcessInfo.processInfo.systemUptime + 0.2 < deadline { try await Task.sleep(for: .milliseconds(200)) }
                }
                guard accepted else {
                    throw ProbeFailure("Actual native provider never reached noUseObserved within 25 seconds. Last cause: \(latest)")
                }
                try fixture.validate()
                try fixture.remove()
                try recordEvidence(directory: evidence, sha: sha, source: fixture.initial)
                print("Actual standalone native idle-use observation and exact fixture cleanup succeeded for \(sha).")
            } catch {
                await printInventoryCounts()
                do { try fixture.remove() }
                catch { print("The uniquely owned standalone fixture was retained because exact cleanup verification failed.") }
                throw error
            }
        } catch {
            FileHandle.standardError.write(Data("Standalone installer idle probe failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// This result is console-only and cannot create idle-use.json. It isolates
    /// the actual shared handle scanner while overall mount eligibility remains
    /// separately required by the unchanged full-provider acceptance below.
    private static func printHandleStageDiagnostics(fixture: ProbeFixture, target: InstallerUseTarget) async {
        var result = ["scope": "current-user-fd-fileport-only", "mountEligibility": "not-evaluated",
                      "positiveControl": "unavailable", "negativeControl": "not-run"]
        do {
            try fixture.validate()
            var duplicate = fcntl(fixture.fd, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw ProbeFailure("The diagnostic duplicate could not be retained.") }
            defer { if duplicate >= 0 { close(duplicate) } }
            let deadline = ProcessInfo.processInfo.systemUptime + 25
            let positive = try await retryHandleDiagnostic(fixture: fixture, target: target, deadline: deadline)
            result["positiveControl"] = handleDiagnosticLabel(positive)
            close(duplicate); duplicate = -1
            if case .observedHandleUse = positive {
                let negative = try await retryHandleDiagnostic(fixture: fixture, target: target, deadline: deadline)
                result["negativeControl"] = handleDiagnosticLabel(negative)
                if case .unavailable(let reason) = negative { result["lastCause"] = reason }
            } else if case .unavailable(let reason) = positive { result["lastCause"] = reason }
            try fixture.validate()
        } catch { result["lastCause"] = "Owned handle-diagnostic fixture validation failed." }
        if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            print("Handle-only diagnostic, not installer eligibility: \(String(decoding: bytes, as: UTF8.self))")
        }
    }

    private static func retryHandleDiagnostic(fixture: ProbeFixture, target: InstallerUseTarget,
                                             deadline: TimeInterval) async throws -> InstallerCurrentUserHandleDiagnostic {
        var latest = InstallerCurrentUserHandleDiagnostic.unavailable(reason: "The diagnostic observation window expired.")
        while ProcessInfo.processInfo.systemUptime < deadline {
            try fixture.validate()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            let provider = NativeInstallerUseEvidenceProvider(maximumDuration: min(8, remaining))
            latest = await provider.currentUserHandleDiagnostic(for: target)
            try fixture.validate()
            if case .unavailable = latest {
                if ProcessInfo.processInfo.systemUptime + 0.2 < deadline { try await Task.sleep(for: .milliseconds(200)) }
            } else { return latest }
        }
        return latest
    }

    private static func handleDiagnosticLabel(_ value: InstallerCurrentUserHandleDiagnostic) -> String {
        switch value {
        case .observedHandleUse: "observedHandleUse"
        case .noHandleUseObserved: "noHandleUseObserved"
        case .unavailable: "unavailable"
        }
    }

    private static func physicalURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < Int(PATH_MAX) else {
            throw ProbeFailure("Invalid hosted fixture temporary path.")
        }
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = path.withCString { source in bytes.withUnsafeMutableBufferPointer { realpath(source, $0.baseAddress) != nil } }
        guard resolved else { throw ProbeFailure("The hosted fixture temporary directory could not be physically resolved.") }
        return URL(fileURLWithPath: bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, isDirectory: true)
    }

    private static func recordEvidence(directory: ProbeDirectory, sha: String, source: ProbeSnapshot) throws {
        let record: [String: Any] = ["schema": 1, "kind": "idle-use", "sourceSHA": sha, "detail": [
            "result": "noUseObserved", "sourceDevice": String(source.device), "sourceInode": String(source.inode), "observedUseControl": "true"
        ]]
        try writeEvidence(record, directory: directory, filename: "idle-use.json")
    }

    /// Current refusal is a different result and filename from positive proof.
    /// A separate source/recipe-bound verifier must validate historical proof;
    /// this method cannot emit the positive artifact or return success exit0.
    private static func recordUnsupportedEnvironment(fixture: ProbeFixture, target: InstallerUseTarget,
        directory: ProbeDirectory, sha: String, fullEvidence: InstallerUseEvidence) async throws {
        guard fullEvidence == .unavailable(reason: InstallerUseEvidence.attachedImageLimitation) else {
            throw ProbeFailure("Only an exact actual attached-image refusal can enter conditional verification.")
        }
        let env = ProcessInfo.processInfo.environment
        guard let providerDigest = env["MOEKIT_INSTALLER_PROVIDER_SHA256"],
              let recipeDigest = env["MOEKIT_INSTALLER_COMPILER_CONTRACT_SHA256"],
              [providerDigest, recipeDigest].allSatisfy({ $0.count == 64 && $0.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) }) else {
            throw ProbeFailure("Conditional evidence requires a verified provider and compiler contract.")
        }
        try fixture.validate()
        let before = try await completeNonemptyInventory()
        var duplicate = fcntl(fixture.fd, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw ProbeFailure("The fresh conditional positive-control handle could not be created.") }
        defer { if duplicate >= 0 { close(duplicate) } }
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        let positive = try await retryHandleDiagnostic(fixture: fixture, target: target, deadline: deadline)
        guard case .observedHandleUse = positive else { throw ProbeFailure("Fresh conditional handle-positive observation failed.") }
        close(duplicate); duplicate = -1
        let negative = try await retryHandleDiagnostic(fixture: fixture, target: target, deadline: deadline)
        guard negative == .noHandleUseObserved else { throw ProbeFailure("Fresh complete conditional handle-negative observation failed.") }
        let after = try await completeNonemptyInventory()
        guard NSArray(array: before).isEqual(to: after) else {
            throw ProbeFailure("The complete unsupported image inventory changed during fresh handle controls.")
        }
        try fixture.validate()
        let source = fixture.initial
        try fixture.remove()
        let record: [String: Any] = ["schema": 1, "kind": "idle-use-unsupported-environment", "sourceSHA": sha,
            "providerSHA256": providerDigest, "compilerContractSHA256": recipeDigest,
            "detail": ["result": "unsupported-current-environment", "fullProviderResult": "unavailable-attached-images",
                       "fullProviderReason": InstallerUseEvidence.attachedImageLimitation,
                       "handlePositiveControl": "observedHandleUse", "handleNegativeControl": "noHandleUseObserved",
                       "inventoryBeforeCount": String(before.count), "inventoryAfterCount": String(after.count),
                       "inventoryStable": "true", "fixtureCleanup": "verified", "priorIdenticalSourcePositiveRequired": "true",
                       "sourceDevice": String(source.device), "sourceInode": String(source.inode)]]
        try writeEvidence(record, directory: directory, filename: "idle-use-unsupported-environment.json")
        print("Unsupported current environment: stable nonempty images and exact full-provider refusal; fresh handle controls passed. Current noUseObserved was NOT established. Prior identical-source positive verification is required.")
    }

    private static func completeNonemptyInventory() async throws -> [[String: Any]] {
        let data = try await InstallerDiskImageInventory.shared.read(deadline: ProcessInfo.processInfo.systemUptime + 8)
        guard !data.isEmpty, data.count <= InstallerDiskImageInventory.maximumOutput,
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let records = root["images"] as? [[String: Any]], !records.isEmpty, records.count <= 64 else {
            throw ProbeFailure("Conditional verification requires a complete bounded nonempty image inventory.")
        }
        var sources: Set<String> = []
        for record in records {
            guard let path = record["image-path"] as? String, path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < Int(PATH_MAX),
                  sources.insert(path).inserted, let entities = record["system-entities"] as? [[String: Any]],
                  !entities.isEmpty, entities.count <= 32 else { throw ProbeFailure("A partial image record prevents conditional verification.") }
            var devices: Set<String> = []
            for entity in entities {
                guard let device = entity["dev-entry"] as? String, safeDevice(device) == device,
                      devices.insert(device).inserted else { throw ProbeFailure("An incomplete or duplicate image device prevents conditional verification.") }
                if let value = entity["mount-point"] {
                    guard let path = value as? String, path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < Int(PATH_MAX) else {
                        throw ProbeFailure("An invalid mounted-image record prevents conditional verification.")
                    }
                }
            }
        }
        return records
    }

    private static func writeEvidence(_ record: [String: Any], directory: ProbeDirectory, filename: String) throws {
        try directory.validate()
        try directory.requirePrivate()
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        guard bytes.count < 8192 else { throw ProbeFailure("The runtime evidence exceeds its byte budget.") }
        let fd = openat(directory.fd, filename, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProbeFailure("Runtime evidence could not be exclusively created.") }
        defer { close(fd) }
        guard bytes.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == bytes.count, fsync(fd) == 0 else {
            throw ProbeFailure("Runtime evidence could not be completely persisted.")
        }
        let snapshot = try ProbeSnapshot.read(fd)
        guard snapshot.regular, snapshot.links == 1, snapshot.uid == geteuid(), snapshot.mode & 0o777 == 0o600,
              snapshot == (try ProbeSnapshot.at(directory.fd, filename)) else {
            throw ProbeFailure("Runtime evidence identity or permissions changed.")
        }
        try requireBytes(fd, expected: bytes)
        try directory.validate()
    }

    /// Counts cover every image record but disclose no source path, volume,
    /// bookmark, arbitrary value or other-user data. Categories are diagnostics,
    /// never exclusions from the production empty-inventory requirement.
    private static func printInventoryCounts() async {
        do {
            let bytes = try await InstallerDiskImageInventory.shared.read(deadline: ProcessInfo.processInfo.systemUptime + 3)
            guard let root = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  let records = root["images"] as? [[String: Any]] else {
                print("Full image inventory diagnostic: malformed root/images."); return
            }
            var counts = ["total": records.count, "ownedFixturePrefix": 0, "coreSimulator": 0,
                          "appleAssets": 0, "developer": 0, "system": 0, "other": 0, "missingSourcePath": 0,
                          "dmgExtension": 0, "otherExtension": 0, "recordsWithMountPoint": 0, "incompleteEntities": 0]
            for record in records {
                if let entities = record["system-entities"] as? [[String: Any]] {
                    if entities.contains(where: { $0["mount-point"] is String }) { counts["recordsWithMountPoint", default: 0] += 1 }
                } else { counts["incompleteEntities", default: 0] += 1 }
                guard let path = record["image-path"] as? String else { counts["missingSourcePath", default: 0] += 1; continue }
                let url = URL(fileURLWithPath: path)
                counts[url.pathExtension.lowercased() == "dmg" ? "dmgExtension" : "otherExtension", default: 0] += 1
                let owned = url.pathComponents.contains { part in
                    ["MoeKit-owned-dmg-", "MoeKit-idle-probe-"].contains { prefix in
                        part.hasPrefix(prefix) && UUID(uuidString: String(part.dropFirst(prefix.count))) != nil
                    }
                }
                let category: String
                if owned { category = "ownedFixturePrefix" }
                else if path.contains("/CoreSimulator/") { category = "coreSimulator" }
                else if path.hasPrefix("/System/Library/Assets") || path.hasPrefix("/Library/Assets") { category = "appleAssets" }
                else if path.hasPrefix("/Library/Developer/") || path.hasPrefix("/Applications/Xcode") { category = "developer" }
                else if path.hasPrefix("/System/") { category = "system" }
                else { category = "other" }
                counts[category, default: 0] += 1
            }
            let encoded = try JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys])
            print("Full image inventory category counts: \(String(decoding: encoded, as: UTF8.self))")
            printImageMetadata(records)
        } catch { print("Full image inventory counts unavailable: \(error)") }
    }

    /// Read-only research evidence, never an eligibility classifier. Retain at
    /// most one source chain and one mounted-directory chain at a time, rather
    /// than exhausting descriptors by pinning every installed system image.
    private static func printImageMetadata(_ records: [[String: Any]]) {
        var emitted = 0
        var account242: [String: Any]?
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        for (index, record) in records.prefix(64).enumerated() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                print("Image metadata diagnostic reached its cooperative five-second budget."); return
            }
            var result: [String: Any] = ["index": index, "sourcePath": "redacted", "diagnosticOnly": true]
            do {
                guard let path = record["image-path"] as? String, path.hasPrefix("/"), !path.utf8.contains(0),
                      path.utf8.count < Int(PATH_MAX), path.split(separator: "/").count <= 32 else {
                    throw ProbeFailure("invalid-or-over-budget-source-path")
                }
                let url = URL(fileURLWithPath: path)
                let parent = try ProbeDirectory.open(url.deletingLastPathComponent())
                var ancestors: [[String: Any]] = [], protectedAncestors = true
                var current: ProbeDirectory? = parent
                while let directory = current {
                    let snapshot = try ProbeSnapshot.read(directory.fd)
                    let acl = aclState(directory.fd)
                    let protected = snapshot.uid == 0 && snapshot.mode & 0o022 == 0 && (acl == "absent" || acl == "empty")
                    var metadata = statMetadata(snapshot)
                    metadata["acl"] = acl; metadata["rootProtected"] = protected; metadata["noFollowPinned"] = true
                    ancestors.append(metadata)
                    protectedAncestors = protectedAncestors && protected
                    current = directory.parent
                }
                result["ancestorsLeafToRoot"] = ancestors
                let named = try ProbeSnapshot.at(parent.fd, url.lastPathComponent)
                result["source"] = statMetadata(named)
                if named.uid == 242 {
                    if account242 == nil { account242 = observedAccount242() }
                    result["observedUID242Account"] = account242
                }
                let fd = openat(parent.fd, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw ProbeFailure("source-not-readable-with-no-follow") }
                defer { close(fd) }
                let held = try ProbeSnapshot.read(fd), acl = aclState(fd)
                result["sourceACL"] = acl
                result["sourceNoFollowPinned"] = true
                guard held == named else { throw ProbeFailure("source-identity-changed") }
                let protected = protectedAncestors && held.regular && held.uid == 0 && held.mode & 0o022 == 0
                    && (acl == "absent" || acl == "empty")
                result["completeSourceRootProtected"] = protected
                let entities = record["system-entities"] as? [[String: Any]]
                result["entitiesCompleteWithinBudget"] = entities != nil && entities!.count <= 32
                result["entities"] = (entities ?? []).prefix(32).map(mountMetadata)
                try parent.validate()
                guard held == (try ProbeSnapshot.read(fd)), held == (try ProbeSnapshot.at(parent.fd, url.lastPathComponent)) else {
                    throw ProbeFailure("source-changed-during-mount-metadata-check")
                }
                // Disclosure is permitted only for the complete, stable,
                // root-protected source path; mount paths are always redacted.
                if protected { result["sourcePath"] = path }
                result["sourceMetadataStable"] = true
            } catch {
                result["sourcePath"] = "redacted"
                result["sourceMetadataStable"] = false
                result["status"] = "incomplete-or-changed"
            }
            guard let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                  bytes.count <= 256 * 1024 - emitted else {
                print("Image metadata diagnostic truncated at its 256 KiB output budget."); return
            }
            emitted += bytes.count
            print("Image metadata diagnostic: \(String(decoding: bytes, as: UTF8.self))")
        }
        if records.count > 64 { print("Image metadata diagnostic truncated at its 64-record budget.") }
    }

    private static func statMetadata(_ s: ProbeSnapshot) -> [String: Any] {
        ["owner": s.uid, "group": s.gid, "mode": String(format: "%04o", s.mode & 0o7777),
         "type": s.regular ? "regular" : (s.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) ? "directory" : "other"),
         "links": s.links, "device": s.device, "inode": s.inode, "flags": s.flags,
         "restrictedFlag": s.flags & UInt32(SF_RESTRICTED) != 0]
    }

    /// Resolve only the actually observed UID242, with a fixed buffer. Never
    /// read/output its password, home directory, or arbitrary account fields.
    /// This is identity research, not an approved-system-account allowlist.
    private static func observedAccount242() -> [String: Any] {
        var entry = passwd(), found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16 * 1_024)
        var result: [String: Any] = buffer.withUnsafeMutableBufferPointer { storage in
            let status = getpwuid_r(242, &entry, storage.baseAddress, storage.count, &found)
            guard status == 0, found != nil, entry.pw_uid == 242,
                  let name = boundedAccountField(entry.pw_name, storage: storage, maximum: 64),
                  !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                return ["uid": 242, "resolved": false, "lookupStatus": status]
            }
            let shell = boundedAccountField(entry.pw_shell, storage: storage, maximum: 128)
            return ["uid": entry.pw_uid, "gid": entry.pw_gid, "resolved": true, "name": name,
                    "nonLoginShell": shell.map { ["/usr/bin/false", "/bin/false", "/usr/sbin/nologin", "/sbin/nologin"].contains($0) } ?? false]
        }
        if let name = result["name"] as? String {
            // Only one lookup per metadata batch; a stalled read is left alone
            // after two seconds, never signalled or replaced by another query.
            let lookup = ProbeLocalAccountLookup()
            DispatchQueue.global(qos: .utility).async { lookup.finish(queryLocalAccount242(expectedName: name)) }
            result["localDefault"] = lookup.wait()
        }
        return result
    }

    private static func queryLocalAccount242(expectedName: String) -> [String: String] {
        do {
            let node = try ODNode(session: ODSession.default(), name: "/Local/Default")
            guard node.nodeName == "/Local/Default" else { return ["status": "unexpected-node"] }
            let attributes: [String] = [kODAttributeTypeRecordName, kODAttributeTypeUniqueID, kODAttributeTypeUserShell]
            let recordType: String = kODRecordTypeUsers
            let query = try ODQuery(node: node, forRecordTypes: recordType, attribute: kODAttributeTypeUniqueID,
                                    matchType: ODMatchType(kODMatchEqualTo), queryValues: "242",
                                    returnAttributes: attributes, maximumResults: 2)
            let rows = try query.resultsAllowingPartial(false)
            guard rows.count == 1, let record = rows.first as? ODRecord,
                  let name = record.recordName, name.utf8.count <= 64, !name.isEmpty,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                  let identifiers = try record.values(forAttribute: kODAttributeTypeUniqueID) as? [String], identifiers == ["242"],
                  let shells = try record.values(forAttribute: kODAttributeTypeUserShell) as? [String], shells.count == 1,
                  let shell = shells.first, shell.utf8.count <= 128 else { return ["status": "missing-ambiguous-or-invalid-record"] }
            return ["status": "one-local-record", "node": "/Local/Default", "uid": "242", "name": name,
                    "matchesGetpwuidName": String(name == expectedName),
                    "nonLoginShell": String(["/usr/bin/false", "/bin/false", "/usr/sbin/nologin", "/sbin/nologin"].contains(shell))]
        } catch { return ["status": "local-record-read-unavailable"] }
    }

    private static func boundedAccountField(_ value: UnsafePointer<CChar>?, storage: UnsafeMutableBufferPointer<CChar>, maximum: Int) -> String? {
        guard let value, let base = storage.baseAddress else { return nil }
        let offset = Int(bitPattern: value) - Int(bitPattern: base)
        guard offset >= 0, offset < storage.count else { return nil }
        let bytes = storage[offset..<min(storage.count, offset + maximum)]
        guard let end = bytes.firstIndex(of: 0) else { return nil }
        return String(bytes: bytes[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    private static func mountMetadata(_ entity: [String: Any]) -> [String: Any] {
        let reportedDevice = entity["dev-entry"] as? String
        var result: [String: Any] = ["reportedDevice": safeDevice(reportedDevice), "mountPath": "redacted"]
        guard let path = entity["mount-point"] as? String else { result["mounted"] = false; return result }
        result["mounted"] = true
        do {
            guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < Int(PATH_MAX),
                  path.split(separator: "/").count <= 32 else { throw ProbeFailure("invalid-mount-path") }
            let directory = try ProbeDirectory.open(URL(fileURLWithPath: path, isDirectory: true))
            var filesystem = statfs()
            guard fstatfs(directory.fd, &filesystem) == 0 else { throw ProbeFailure("mount-metadata-unreadable") }
            let actualDevice = withUnsafeBytes(of: &filesystem.f_mntfromname) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            let actualMount = withUnsafeBytes(of: &filesystem.f_mntonname) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            result["actualDevice"] = safeDevice(actualDevice)
            result["reportedDeviceMatchesStatfs"] = reportedDevice == actualDevice && safeDevice(actualDevice) != "redacted-or-missing"
            result["reportedMountMatchesStatfs"] = URL(fileURLWithPath: actualMount).path == directory.url.path
            result["readOnly"] = filesystem.f_flags & UInt32(MNT_RDONLY) != 0
            result["filesystemFlags"] = filesystem.f_flags
            result["mountDirectoryDevice"] = directory.initial.device
            result["mountDirectoryInode"] = directory.initial.inode
            result["filesystemType"] = withUnsafeBytes(of: &filesystem.f_fstypename) { bytes -> String in
                let type = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                return ["apfs", "hfs", "udf", "cd9660"].contains(type) ? type : "other"
            }
            try directory.validate()
            var after = statfs()
            guard fstatfs(directory.fd, &after) == 0, after.f_flags == filesystem.f_flags,
                  withUnsafeBytes(of: &after.f_mntfromname, { Array($0) }) == withUnsafeBytes(of: &filesystem.f_mntfromname, { Array($0) }),
                  withUnsafeBytes(of: &after.f_mntonname, { Array($0) }) == withUnsafeBytes(of: &filesystem.f_mntonname, { Array($0) }) else {
                throw ProbeFailure("mount-metadata-changed")
            }
            result["mountMetadataStable"] = true
        } catch { result["mountMetadataStable"] = false }
        return result
    }

    private static func safeDevice(_ value: String?) -> String {
        guard let value, value.hasPrefix("/dev/disk"), (10...40).contains(value.utf8.count) else { return "redacted-or-missing" }
        let numbers = value.dropFirst(9).split(separator: "s", omittingEmptySubsequences: false)
        guard numbers.count <= 3, numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else {
            return "redacted-or-missing"
        }
        return value
    }

    private static func aclState(_ fd: Int32) -> String {
        guard let security = filesec_init() else { return "unavailable" }
        defer { filesec_free(security) }
        var metadata = stat(), hasACL: Int32 = 0
        guard fstatx_np(fd, &metadata, security) == 0,
              filesec_query_property(security, FILESEC_ACL, &hasACL) == 0 else { return "unavailable" }
        if hasACL == 0 { return "absent" }
        // A successful nonzero filesec presence value is a validity mask.
        var value: acl_t?
        guard filesec_get_property(security, FILESEC_ACL, &value) == 0, let acl = value else { return "unavailable" }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return "invalid" }
        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        if result == 0 { return "present" }
        return result == -1 && errno == EINVAL ? "empty" : "unavailable"
    }

    fileprivate static func requireBytes(_ fd: Int32, expected: Data) throws {
        var bytes = [UInt8](repeating: 0, count: expected.count + 1)
        let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count == expected.count, Data(bytes.prefix(expected.count)) == expected else {
            throw ProbeFailure("The held owned-file bytes do not match the expected complete bytes.")
        }
    }
}

private final class ProbeLocalAccountLookup: @unchecked Sendable {
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var value: [String: String]?
    func finish(_ result: [String: String]) {
        lock.withLock { value = result }
        completed.signal()
    }
    func wait() -> [String: String] {
        guard completed.wait(timeout: .now() + 2) == .success else { return ["status": "local-record-read-timed-out"] }
        return lock.withLock { value ?? ["status": "local-record-read-unavailable"] }
    }
}

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct ProbeSnapshot: Equatable {
    let device: UInt64, inode: UInt64, links: UInt64
    let mode: UInt32, uid: UInt32, gid: UInt32, flags: UInt32
    let size: Int64, mtime: Int64, mtimeNS: Int64, ctime: Int64, ctimeNS: Int64
    var regular: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
    init(_ s: stat) {
        device = UInt64(UInt32(bitPattern: s.st_dev)); inode = UInt64(s.st_ino); links = UInt64(s.st_nlink)
        mode = UInt32(s.st_mode); uid = s.st_uid; gid = s.st_gid; flags = s.st_flags
        size = s.st_size; mtime = Int64(s.st_mtimespec.tv_sec); mtimeNS = Int64(s.st_mtimespec.tv_nsec)
        ctime = Int64(s.st_ctimespec.tv_sec); ctimeNS = Int64(s.st_ctimespec.tv_nsec)
    }
    static func read(_ fd: Int32) throws -> Self {
        var s = stat()
        guard fstat(fd, &s) == 0 else { throw ProbeFailure("An owned descriptor snapshot could not be read.") }
        return .init(s)
    }
    static func at(_ fd: Int32, _ name: String) throws -> Self {
        var s = stat()
        guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw ProbeFailure("An owned named snapshot could not be read.") }
        return .init(s)
    }
    func sameDirectory(_ other: Self) -> Bool {
        mode & UInt32(S_IFMT) == UInt32(S_IFDIR) && device == other.device && inode == other.inode
            && mode == other.mode && uid == other.uid && gid == other.gid && flags == other.flags
    }
}

/// Retains a strict no-follow chain; parent replacement invalidates validation.
private final class ProbeDirectory {
    let url: URL, fd: Int32, initial: ProbeSnapshot
    let parent: ProbeDirectory?
    let name: String?
    private init(url: URL, fd: Int32, parent: ProbeDirectory?, name: String?) throws {
        self.url = url; self.fd = fd; self.parent = parent; self.name = name
        initial = try ProbeSnapshot.read(fd)
        guard initial.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else { throw ProbeFailure("An owned directory is not a directory.") }
    }
    deinit { close(fd) }
    static func open(_ url: URL) throws -> ProbeDirectory {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0), url.path.utf8.count < Int(PATH_MAX) else {
            throw ProbeFailure("Invalid native directory path.")
        }
        let components = url.path.split(separator: "/").map(String.init)
        guard components.count <= 100 else { throw ProbeFailure("Native directory path exceeds its depth budget.") }
        let fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProbeFailure("The directory root could not be pinned.") }
        var directory: ProbeDirectory
        do { directory = try .init(url: URL(fileURLWithPath: "/"), fd: fd, parent: nil, name: nil) }
        catch { close(fd); throw error }
        for component in components { directory = try directory.child(component) }
        return directory
    }
    func child(_ name: String) throws -> ProbeDirectory {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0), name.utf8.count <= 255 else {
            throw ProbeFailure("Invalid owned basename.")
        }
        try validate()
        let descriptor = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProbeFailure("An owned directory could not be pinned without following links.") }
        let child: ProbeDirectory
        do { child = try .init(url: url.appendingPathComponent(name, isDirectory: true), fd: descriptor, parent: self, name: name) }
        catch { close(descriptor); throw error }
        try child.validate()
        return child
    }
    func validate() throws {
        if let parent, let name {
            try parent.validate()
            guard initial.sameDirectory(try ProbeSnapshot.at(parent.fd, name)) else { throw ProbeFailure("An owned directory path changed.") }
        }
        guard initial.sameDirectory(try ProbeSnapshot.read(fd)) else { throw ProbeFailure("An owned directory descriptor changed.") }
    }
    func requirePrivate() throws {
        try validate()
        let s = try ProbeSnapshot.read(fd)
        guard s.uid == geteuid(), s.mode & 0o777 == 0o700, s.flags == 0,
              let security = filesec_init() else { throw ProbeFailure("The owned directory must be private and owned by the CI user.") }
        defer { filesec_free(security) }
        var metadata = stat(), hasACL: Int32 = 0
        guard fstatx_np(fd, &metadata, security) == 0,
              filesec_query_property(security, FILESEC_ACL, &hasACL) == 0,
              s.sameDirectory(ProbeSnapshot(metadata)) else { throw ProbeFailure("The private directory's ACL could not be verified.") }
        if hasACL == 0 { return }
        // A successful nonzero filesec presence value is a validity mask.
        var value: acl_t?
        guard filesec_get_property(security, FILESEC_ACL, &value) == 0, let acl = value else {
            throw ProbeFailure("The private directory's ACL could not be read.")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw ProbeFailure("The private directory's ACL is invalid.") }
        var entry: acl_entry_t?
        errno = 0
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else {
            throw ProbeFailure("The owned directory has an unexpected ACL entry.")
        }
    }
}

private final class ProbeFixture {
    let root: ProbeDirectory, fd: Int32, initial: ProbeSnapshot, bytes: Data
    let marker = "owned-idle-marker.dmg"
    var fileURL: URL { root.url.appendingPathComponent(marker) }
    private var removed = false
    init(parent: ProbeDirectory) throws {
        let token = UUID().uuidString, name = "MoeKit-idle-probe-" + UUID().uuidString
        let markerBytes = Data("MoeKit standalone idle fixture \(token)\n".utf8)
        try parent.validate()
        guard mkdirat(parent.fd, name, 0o700) == 0 else { throw ProbeFailure("The unique owned fixture root could not be created.") }
        // Incomplete creation retains its unique root rather than deleting an
        // object whose full marker and identity have not been established.
        let ownedRoot = try parent.child(name)
        try ownedRoot.requirePrivate()
        let descriptor = openat(ownedRoot.fd, "owned-idle-marker.dmg", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ProbeFailure("The owned marker could not be exclusively created.") }
        let snapshot: ProbeSnapshot
        do {
            guard markerBytes.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == markerBytes.count, fsync(descriptor) == 0 else {
                throw ProbeFailure("The complete owned marker could not be written.")
            }
            snapshot = try ProbeSnapshot.read(descriptor)
        } catch { close(descriptor); throw error }
        root = ownedRoot; fd = descriptor; initial = snapshot; bytes = markerBytes
        try validate()
    }
    deinit { close(fd) }
    func validate() throws {
        guard !removed else { throw ProbeFailure("The owned fixture was already removed.") }
        try root.validate()
        try root.requirePrivate()
        guard initial.regular, initial.links == 1, initial.uid == geteuid(), initial.mode & 0o777 == 0o600,
              initial.flags == 0, initial.size == bytes.count,
              initial == (try ProbeSnapshot.read(fd)), initial == (try ProbeSnapshot.at(root.fd, marker)),
              Set(try FileManager.default.contentsOfDirectory(atPath: root.url.path)) == [marker] else {
            throw ProbeFailure("The owned fixture identity, permissions or exact members changed.")
        }
        try InstallerIdleProbe.requireBytes(fd, expected: bytes)
        guard initial == (try ProbeSnapshot.read(fd)) else { throw ProbeFailure("The owned fixture changed during byte verification.") }
        try root.validate()
    }
    func remove() throws {
        if removed { return }
        try validate()
        guard let parent = root.parent, let name = root.name,
              unlinkat(root.fd, marker, 0) == 0 else { throw ProbeFailure("The verified owned marker could not be removed.") }
        try root.validate()
        guard try FileManager.default.contentsOfDirectory(atPath: root.url.path).isEmpty,
              unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 else { throw ProbeFailure("The empty verified owned fixture root could not be removed.") }
        removed = true
    }
}
