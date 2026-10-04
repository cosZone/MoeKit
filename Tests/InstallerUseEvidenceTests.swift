import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MoeKit

struct InstallerUseEvidenceTests {
    private let target = InstallerUseTarget(device: 7, inode: 81, path: "/fixture/Downloads/owned.dmg",
                                            observerRetainedFileDescriptors: [4])

    @Test("Scoped absence requires both complete process lists, all identities and both image observations")
    func completeScopedAbsence() async {
        let fixture = InstallerUseFixture()
        let result = await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target)
        #expect(result == .noUseObserved)
        #expect(fixture.processListCalls == 2)
        #expect(fixture.imageCalls == 2)
        #expect(fixture.identityCalls == 3)
        #expect(!InstallerUseEvidence.scopeDescription.isEmpty)
    }

    @Test("A separately typed handle-only diagnostic never grants mounted-image eligibility")
    func handleDiagnosticIsNotFullEligibility() async {
        let fixture = InstallerUseFixture(images: [[.init(device: 7, inode: 99)]])
        let provider = NativeInstallerUseEvidenceProvider(system: fixture)
        let diagnostic: InstallerCurrentUserHandleDiagnostic = await provider.currentUserHandleDiagnostic(for: target)
        #expect(diagnostic == .noHandleUseObserved)
        #expect(fixture.processListCalls == 2)
        #expect(fixture.identityCalls == 3)
        #expect(fixture.imageCalls == 0)
        let fullEvidence: InstallerUseEvidence = await provider.evidence(for: target)
        #expect(fullEvidence == .unavailable(reason: InstallerUseEvidence.attachedImageLimitation))
        #expect(fixture.processListCalls == 2)
        #expect(fixture.imageCalls == 1)
    }

    @Test("Handle diagnostics share duplicate detection and keep permission failure unknown")
    func handleDiagnosticPositiveAndUnknown() async {
        let duplicate = InstallerUseFixture(descriptorLists: [[.init(number: 4, isVnode: true), .init(number: 5, isVnode: true)]],
                                            failure: "mounts")
        let positive = await NativeInstallerUseEvidenceProvider(system: duplicate).currentUserHandleDiagnostic(for: target)
        if case .observedHandleUse = positive {} else { Issue.record("The handle diagnostic missed the unexcluded duplicate.") }
        #expect(duplicate.imageCalls == 0)
        let denied = InstallerUseFixture(failure: "descriptors")
        let unknown = await NativeInstallerUseEvidenceProvider(system: denied).currentUserHandleDiagnostic(for: target)
        if case .unavailable = unknown {} else { Issue.record("The handle diagnostic converted a read failure into absence.") }
        #expect(denied.imageCalls == 0)
    }

    @Test("Exclude one retained target FD, never the entire observer process")
    func anotherSelfDescriptorBlocks() async {
        let fixture = InstallerUseFixture(descriptorLists: [[.init(number: 4, isVnode: true), .init(number: 5, isVnode: true)]])
        let result = await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target)
        #expect(isObserved(result))
    }

    @Test("Other-user identity unexpectedly returned in current-user scope is unavailable")
    func wrongOwnerBlocks() async {
        let fixture = InstallerUseFixture(identities: [.init(pid: 31, uid: 999, startSeconds: 1, startMicroseconds: 0, isZombie: false)])
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target)))
    }

    @Test("Only a stable, verified zombie can skip released process handles")
    func verifiedZombieHasNoHandles() async {
        let zombie = InstallerUseProcessIdentity(pid: 32, uid: 501, startSeconds: 1, startMicroseconds: 0, isZombie: true)
        let observer = InstallerUseProcessIdentity(pid: 31, uid: 501, startSeconds: 1, startMicroseconds: 0, isZombie: false)
        let fixture = InstallerUseFixture(processLists: [[31, 32]],
            identities: [observer, observer, zombie, zombie, observer, zombie])
        #expect(await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target) == .noUseObserved)
    }

    @Test("Current-user vnode fileports count even after the original FD closes")
    func fileportBlocks() async {
        let fixture = InstallerUseFixture(portLists: [[.init(number: 103, isVnode: true)]])
        #expect(isObserved(await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target)))
    }

    @Test("Any nonempty mounted inventory blocks before process reads")
    func mountBlocks() async {
        let fixture = InstallerUseFixture(images: [[.init(device: 7, inode: 81)]])
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target)))
        #expect(fixture.processListCalls == 0)
    }

    @Test("Any image attached during the observation blocks")
    func secondMountBlocks() async {
        let fixture = InstallerUseFixture(images: [[], [.init(device: 7, inode: 81)]])
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target)))
    }

    @Test("Changing unrelated mounted inventory is unavailable")
    func mountChurnBlocks() async {
        let fixture = InstallerUseFixture(images: [[], [.init(device: 7, inode: 82)]])
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target)))
    }

    @Test("New, missing or duplicate process rows block a negative result")
    func processChurnBlocks() async {
        let cases: [[[Int32]]] = [[[31], [31, 32]], [[31], []], [[31, 31]]]
        for lists in cases {
            let fixture = InstallerUseFixture(processLists: lists)
            #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target)))
        }
    }

    @Test("PID reuse in either identity recheck blocks")
    func identityChurnBlocks() async {
        let original = InstallerUseProcessIdentity(pid: 31, uid: 501, startSeconds: 1, startMicroseconds: 0, isZombie: false)
        let reused = InstallerUseProcessIdentity(pid: 31, uid: 501, startSeconds: 2, startMicroseconds: 0, isZombie: false)
        for identities in [[original, reused], [original, original, reused]] {
            let fixture = InstallerUseFixture(identities: identities)
            #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target)))
        }
    }

    @Test("Descriptor or fileport list churn blocks")
    func handleChurnBlocks() async {
        let descriptorFixture = InstallerUseFixture(descriptorLists: [[.init(number: 4, isVnode: true)], []])
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: descriptorFixture).evidence(for: target)))
        let portFixture = InstallerUseFixture(portLists: [[], [.init(number: 103, isVnode: true)]])
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: portFixture).evidence(for: target)))
    }

    @Test("Same-number vnode descriptor and fileport reuse blocks")
    func sameHandleDifferentVnodeBlocks() async {
        let changedFD = InstallerUseFixture(descriptorFiles: [.init(device: 7, inode: 81), .init(device: 7, inode: 99)])
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: changedFD).evidence(for: target)))
        let changedPort = InstallerUseFixture(portLists: [[.init(number: 103, isVnode: true)]],
            portFiles: [.init(device: 7, inode: 90), .init(device: 7, inode: 99)])
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: changedPort).evidence(for: target)))
    }

    @Test("A missing retained FD or a claimed retained FD for a different file blocks")
    func invalidExclusionBlocks() async {
        let missing = InstallerUseFixture(descriptorLists: [[]])
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: missing).evidence(for: target)))
        let reused = InstallerUseFixture(descriptorFile: .init(device: 7, inode: 999))
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: reused).evidence(for: target)))
    }

    @Test("Unknown process, descriptor, fileport or mounted inventory is never absence")
    func readFailuresBlock() async {
        for failure in ["processes", "identity", "descriptors", "fileports", "descriptor", "mounts"] {
            let fixture = InstallerUseFixture(failure: failure)
            #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target)))
        }
        let fixture = InstallerUseFixture(portLists: [[.init(number: 103, isVnode: true)]], failure: "port")
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: fixture).evidence(for: target)))
    }

    @Test("Time, process and descriptor budgets fail closed")
    func budgetsBlock() async {
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: InstallerUseFixture(), maximumDuration: 0).evidence(for: target)))
        let expired = InstallerUseFixture(clockStep: 30)
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: expired).evidence(for: target)))
        let saturated = InstallerUseFixture(processLists: [[31, 32]])
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: saturated, maximumProcesses: 1).evidence(for: target)))
        let handles = InstallerUseFixture(descriptorLists: [[.init(number: 4, isVnode: true), .init(number: 5, isVnode: false)]])
        #expect(isUnavailable(await NativeInstallerUseEvidenceProvider(system: handles, maximumHandles: 1).evidence(for: target)))
    }

    @Test("Cancellation cannot produce scoped absence")
    func cancelledBlocks() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await NativeInstallerUseEvidenceProvider(system: InstallerUseFixture()).evidence(for: target)
        }
        #expect(isUnavailable(await task.value))
    }

    @Test("Native list parser disambiguates zero/error, malformed byte counts and saturation")
    func nativeListParsing() throws {
        #expect(try InstallerUseNativeParsing.listCount(bytes: 0, error: 0, stride: 8, maximum: 8, permitsEmpty: true) == 0)
        #expect(try InstallerUseNativeParsing.listCount(bytes: 64, error: 0, stride: 8, maximum: 8, permitsEmpty: true) == 8)
        let invalid: [(Int32, Int32)] = [(0, EPERM), (-1, ESRCH), (1, 0), (72, 0)]
        for tuple in invalid {
            #expect(throws: InstallerUseReadError.self) {
                try InstallerUseNativeParsing.listCount(bytes: tuple.0, error: tuple.1, stride: 8, maximum: 8, permitsEmpty: true)
            }
        }
        #expect(throws: InstallerUseReadError.self) {
            try InstallerUseNativeParsing.listCount(bytes: 0, error: 0, stride: 4, maximum: 8, permitsEmpty: false)
        }
    }

    @Test("Device bit patterns and zero native identities are checked")
    func vnodeIdentityParsing() throws {
        var value = vinfo_stat()
        #expect(throws: InstallerUseReadError.self) { try InstallerUseNativeParsing.fileIdentity(value) }
        value.vst_dev = UInt32.max
        value.vst_ino = 81
        value.vst_mode = UInt16(S_IFREG)
        #expect(try InstallerUseNativeParsing.fileIdentity(value) == .init(device: UInt64(UInt32.max), inode: 81))
    }

    @Test("Empty image inventory is supported; malformed and incomplete records block")
    func mountParsing() throws {
        try InstallerUseNativeParsing.requireEmptyMountedInventory(data: plist(["images": []]))
        let invalid: [[String: Any]] = [[:], ["images": "wrong"], ["images": [["image-path": "/fixture/a.dmg"]]],
            ["images": [["image-path": "relative", "image-alias": Data([1])]]],
            ["images": [["image-path": "/fixture/a.dmg", "image-alias": Data()]]]]
        for object in invalid {
            #expect(throws: (any Error).self) { try InstallerUseNativeParsing.requireEmptyMountedInventory(data: plist(object)) }
        }
        #expect(throws: (any Error).self) { try InstallerUseNativeParsing.requireEmptyMountedInventory(data: Data([0xFF])) }
    }

    @Test("Every nonempty image inventory blocks without source-path exceptions")
    func nonemptyMountInventoryAlwaysBlocks() throws {
        let records: [[String: Any]] = [[:], ["image-path": "/fixture/unrelated.dmg"],
            ["image-path": "/fixture/a.dmg", "image-alias": Data([1])],
            ["image-path": "/fixture/a.dmg", "shadow-path": "/fixture/shadow"]]
        for record in records {
            #expect(throws: InstallerUseReadError.self) {
                try InstallerUseNativeParsing.requireEmptyMountedInventory(data: plist(["images": [record]]))
            }
        }
    }

    @Test("Native vnode FD identity detects an exact owned fixture and its duplicate")
    func nativeOwnedDescriptor() throws {
        let fixture = try InstallerOwnedUseFixture()
        defer { fixture.remove() }
        let fd = open(fixture.file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let duplicate = dup(fd)
        #expect(duplicate >= 0)
        guard duplicate >= 0 else { return }
        defer { close(duplicate) }
        let native = NativeInstallerUseSystem()
        let expected = try InstallerUseNativeParsing.identity(at: fixture.file)
        #expect(try native.descriptorIdentity(pid: getpid(), descriptor: fd) == expected)
        #expect(try native.descriptorIdentity(pid: getpid(), descriptor: duplicate) == expected)
        let handles = try native.descriptors(pid: getpid(), maximum: 16_384)
        #expect(handles.contains(.init(number: UInt32(fd), isVnode: true)))
        #expect(handles.contains(.init(number: UInt32(duplicate), isVnode: true)))
        let identity = try native.identity(pid: getpid())
        #expect(identity.pid == getpid())
        #expect(identity.uid == geteuid())
        #expect(identity.startSeconds > 0)
        #expect(!identity.isZombie)
    }

    @Test("Native fileport retains owned fixture identity after its descriptor closes")
    func nativeOwnedFileport() throws {
        let fixture = try InstallerOwnedUseFixture()
        defer { fixture.remove() }
        let fd = open(fixture.file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        var port: mach_port_t = 0
        let made = fileport_makeport(fd, &port)
        close(fd)
        #expect(made == 0)
        guard made == 0 else { return }
        defer { mach_port_deallocate(mach_task_self_, port) }
        let native = NativeInstallerUseSystem()
        #expect(try native.fileportIdentity(pid: getpid(), port: port) == InstallerUseNativeParsing.identity(at: fixture.file))
        #expect(try native.fileports(pid: getpid(), maximum: 16_384).contains(.init(number: port, isVnode: true)))
    }

    @Test("CI-only real current-user provider reaches scoped absence for an idle owned fixture",
          .enabled(if: InstallerUseCIFixtureGate.enabled("MOEKIT_INSTALLER_IDLE_FIXTURE"),
                   "Run separately, after the normal test suite, on opted-in ephemeral CI"))
    func nativeIdleCurrentUserCoverage() async throws {
        try InstallerUseCIFixtureGate.requireHostedRunner()
        let fixture = try InstallerOwnedUseFixture()
        defer { fixture.remove() }
        let fd = open(fixture.file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let file = try InstallerUseNativeParsing.identity(at: fixture.file)
        let target = InstallerUseTarget(device: file.device, inode: file.inode, path: fixture.file.path,
                                        observerRetainedFileDescriptors: [fd])
        // A fresh complete scan may be retried for ordinary CI process churn,
        // but permission failures are never excluded or converted into success.
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        var latest = "No complete observation finished."
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            let provider = NativeInstallerUseEvidenceProvider(maximumDuration: min(8, remaining))
            switch await provider.evidence(for: target) {
            case .noUseObserved:
                try InstallerNativeFixtureEvidence.record(kind: "idle-use", detail: [
                    "sourceDevice": String(file.device), "sourceInode": String(file.inode),
                    "result": "noUseObserved"
                ])
                return
            case .observedUse(let reason):
                Issue.record("Unexpected real use of the idle owned fixture: \(reason)")
                return
            case .unavailable(let reason):
                latest = reason
            }
            if ProcessInfo.processInfo.systemUptime + 0.2 < deadline { try await Task.sleep(for: .milliseconds(200)) }
        }
        let imageCounts = await InstallerUseCIFixtureGate.imageCountDiagnostics()
        Issue.record("Real current-user file-use coverage never completed within 25 seconds; source activation remains blocked. Last cause: \(latest). \(imageCounts)")
    }

    @Test("CI-only owned DMG attachment verifies production refusal and safe fixture detach",
          .enabled(if: InstallerMountFixtureCI.isEnabled,
                   "Requires explicit opt-in on a secret-free ephemeral GitHub-hosted macOS runner"))
    func nativeMountedImageFixture() async throws {
        try InstallerUseCIFixtureGate.requireHostedRunner()
        let fixture = try InstallerMountFixtureCI()
        do {
            try fixture.createAndAttach()
            let data = try await InstallerDiskImageInventory.shared.read(deadline: ProcessInfo.processInfo.systemUptime + 15)
            _ = try fixture.record(in: data)
            let source = try fixture.imageIdentity()
            #expect(throws: InstallerUseReadError.self) {
                try InstallerUseNativeParsing.requireEmptyMountedInventory(data: data)
            }
            let provider = NativeInstallerUseEvidenceProvider()
            let refusal = await provider.evidence(for: try fixture.useTarget())
            try #require(refusal == .unavailable(reason: InstallerUseEvidence.attachedImageLimitation))
            try await fixture.verifyCrossDeviceMoveRefused()
            try await fixture.detachAndRemove()
            try InstallerNativeFixtureEvidence.record(kind: "mounted-image", detail: [
                "sourceDevice": String(source.device), "sourceInode": String(source.inode),
                "result": "verified-attach-and-detach", "observedRefusal": "true",
                "crossDeviceRefusal": "true"
            ])
        } catch {
            // Cleanup still verifies the newly observed source/device/marker.
            // On ambiguity the uniquely owned fixture is retained, never forced.
            do { try await fixture.detachAndRemove() }
            catch { Issue.record("Owned disk-image fixture retained because cleanup identity could not be verified: \(fixture.root.path)") }
            throw error
        }
    }

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    private func isObserved(_ result: InstallerUseEvidence) -> Bool {
        if case .observedUse = result { return true }; return false
    }
    private func isUnavailable(_ result: InstallerUseEvidence) -> Bool {
        if case .unavailable = result { return true }; return false
    }
}

/// All mutable fixture counters/sequences are lock-protected. No live process
/// enumeration or system helper is used by this injected coverage model.
private final class InstallerUseFixture: InstallerUseSystemReading, @unchecked Sendable {
    let currentUID: UInt32 = 501
    let observerPID: Int32 = 31
    private let lock = NSLock()
    private var pids: [[Int32]]
    private var identities: [InstallerUseProcessIdentity]
    private var fds: [[InstallerUseHandle]]
    private var ports: [[InstallerUseHandle]]
    private var images: [Set<InstallerUseFileIdentity>]
    private var descriptorFiles: [InstallerUseFileIdentity]
    private var portFiles: [InstallerUseFileIdentity]
    private let failure: String?
    private let clockStep: TimeInterval
    private var clock: TimeInterval = 0
    private var processCount = 0, imageCount = 0, identityCount = 0
    var processListCalls: Int { lock.withLock { processCount } }
    var imageCalls: Int { lock.withLock { imageCount } }
    var identityCalls: Int { lock.withLock { identityCount } }

    init(processLists: [[Int32]] = [[31]],
         identities: [InstallerUseProcessIdentity] = [.init(pid: 31, uid: 501, startSeconds: 1, startMicroseconds: 0, isZombie: false)],
         descriptorLists: [[InstallerUseHandle]] = [[.init(number: 4, isVnode: true)]],
         portLists: [[InstallerUseHandle]] = [[]], images: [Set<InstallerUseFileIdentity>] = [[]],
         descriptorFile: InstallerUseFileIdentity = .init(device: 7, inode: 81),
         descriptorFiles: [InstallerUseFileIdentity]? = nil,
         portFiles: [InstallerUseFileIdentity] = [.init(device: 7, inode: 81)],
         failure: String? = nil, clockStep: TimeInterval = 0) {
        pids = processLists; self.identities = identities; fds = descriptorLists; ports = portLists
        self.images = images; self.descriptorFiles = descriptorFiles ?? [descriptorFile]
        self.portFiles = portFiles; self.failure = failure; self.clockStep = clockStep
    }
    func now() -> TimeInterval { lock.withLock { clock += clockStep; return clock } }
    func processes(maximum: Int) throws -> [Int32] {
        try lock.withLock { try fail("processes"); processCount += 1; return next(&pids) }
    }
    func identity(pid: Int32) throws -> InstallerUseProcessIdentity {
        try lock.withLock { try fail("identity"); identityCount += 1; return next(&identities) }
    }
    func descriptors(pid: Int32, maximum: Int) throws -> [InstallerUseHandle] {
        try lock.withLock { try fail("descriptors"); return next(&fds) }
    }
    func fileports(pid: Int32, maximum: Int) throws -> [InstallerUseHandle] {
        try lock.withLock { try fail("fileports"); return next(&ports) }
    }
    func descriptorIdentity(pid: Int32, descriptor: Int32) throws -> InstallerUseFileIdentity {
        try lock.withLock { try fail("descriptor"); return next(&descriptorFiles) }
    }
    func fileportIdentity(pid: Int32, port: UInt32) throws -> InstallerUseFileIdentity {
        try lock.withLock { try fail("port"); return next(&portFiles) }
    }
    func mountedImages(deadline: TimeInterval) async throws -> Set<InstallerUseFileIdentity> {
        try lock.withLock { try fail("mounts"); imageCount += 1; return next(&images) }
    }
    private func fail(_ operation: String) throws {
        if failure == operation { throw InstallerUseReadError.unavailable("Injected denied or incomplete read.") }
    }
    private func next<T>(_ values: inout [T]) -> T {
        if values.count > 1 { return values.removeFirst() }
        return values[0]
    }
}

private struct InstallerOwnedUseFixture {
    let root: URL
    let file: URL
    private let marker: Data
    private let rootIdentity: InstallerUseFileIdentity
    private let fileIdentity: InstallerUseFileIdentity

    init() throws {
        let token = UUID().uuidString
        root = try InstallerUseCIFixtureGate.physicalTemporaryDirectory().appendingPathComponent("MoeKit-installer-use-\(token)", isDirectory: true)
        file = root.appendingPathComponent("owned.dmg")
        marker = Data("MoeKit owned descriptor fixture \(token)\n".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        rootIdentity = try InstallerUseNativeParsing.identity(at: root)
        // If creation fails, retain the unique directory rather than recursively
        // deleting a path whose complete contents/identity were not captured.
        try marker.write(to: file, options: .withoutOverwriting)
        fileIdentity = try InstallerUseNativeParsing.identity(at: file)
    }

    func remove() {
        do {
            var directory = stat(), regular = stat()
            guard lstat(root.path, &directory) == 0, (directory.st_mode & S_IFMT) == S_IFDIR,
                  lstat(file.path, &regular) == 0, (regular.st_mode & S_IFMT) == S_IFREG,
                  regular.st_nlink == 1,
                  try InstallerUseNativeParsing.identity(at: root) == rootIdentity,
                  try InstallerUseNativeParsing.identity(at: file) == fileIdentity,
                  try Data(contentsOf: file) == marker,
                  Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == [file.lastPathComponent] else {
                Issue.record("Owned descriptor fixture retained because identity/marker/members changed.")
                return
            }
            guard unlink(file.path) == 0, rmdir(root.path) == 0 else {
                Issue.record("Owned descriptor fixture retained after exact-member cleanup failed.")
                return
            }
        } catch { Issue.record("Owned descriptor fixture retained because cleanup validation failed.") }
    }
}

/// Only the explicitly opted-in, ephemeral secret-free CI job may mount this
/// test-owned image. Normal local testing always skips it. The source consists
/// solely of a generated marker, and cleanup never scans Downloads or Trash.
private final class InstallerMountFixtureCI {
    static var isEnabled: Bool { InstallerUseCIFixtureGate.enabled("MOEKIT_INSTALLER_MOUNT_FIXTURE") }
    let root: URL
    private let content: URL
    private let marker: URL
    private let image: URL
    private let markerBytes: Data
    private let rootIdentity: InstallerUseFileIdentity
    private let contentIdentity: InstallerUseFileIdentity
    private let markerIdentity: InstallerUseFileIdentity
    private let volume: String
    private var disk: String?
    private var createdImageIdentity: InstallerUseFileIdentity?
    private var sourceAnchor: InstallerDirectoryAnchor?
    private var retainedSource: InstallerFileDescriptor?
    private var sourceSnapshot: InstallerFileSnapshot?
    private var cleaned = false

    init() throws {
        guard Self.isEnabled else { throw InstallerUseReadError.unavailable("Mount fixtures require explicit ephemeral CI opt-in.") }
        try InstallerUseCIFixtureGate.requireHostedRunner()
        let token = UUID().uuidString
        root = try InstallerUseCIFixtureGate.physicalTemporaryDirectory().appendingPathComponent("MoeKit-owned-dmg-\(token)", isDirectory: true)
        content = root.appendingPathComponent("content", isDirectory: true)
        marker = content.appendingPathComponent("moekit-owned-fixture.txt")
        image = root.appendingPathComponent("owned.dmg")
        markerBytes = Data("MoeKit synthetic disk-image fixture \(token)\n".utf8)
        volume = "MoeKitFixture-" + String(token.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        rootIdentity = try InstallerUseNativeParsing.identity(at: root)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false)
        try markerBytes.write(to: marker, options: .withoutOverwriting)
        contentIdentity = try InstallerUseNativeParsing.identity(at: content)
        markerIdentity = try InstallerUseNativeParsing.identity(at: marker)
    }

    func createAndAttach() throws {
        var stage = "pre-create ownership validation"
        do {
            try verifyOwnedContent()
            guard Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["content"] else {
                throw InstallerUseReadError.unavailable("Unexpected fixture member before image creation; retain it.")
            }
            stage = "open strict owned directory anchor before create"
            let anchor = try InstallerDirectoryAnchor.open(root)
            sourceAnchor = anchor
            stage = "create owned image"
            _ = try run(["create", "-srcfolder", content.path, "-volname", volume, "-format", "UDZO", image.path])
            try anchor.validate()
            stage = "retain owned image descriptor"
            let retained = try InstallerFileDescriptor(parent: anchor, name: image.lastPathComponent)
            stage = "capture original owned image snapshot"
            let snapshot = try InstallerFileAccess.snapshot(retained.fd)
            guard snapshot == (try InstallerFileAccess.snapshotAt(anchor.fd, image.lastPathComponent)) else {
                throw InstallerUseReadError.unavailable("The owned source changed before its retention handle was established.")
            }
            sourceAnchor = anchor
            retainedSource = retained
            sourceSnapshot = snapshot
            createdImageIdentity = .init(device: snapshot.device, inode: snapshot.inode)
            stage = "pre-attach full source revalidation"
            try verifyOwnedContent()
            _ = try imageIdentity()
            let originalDigest = try Self.digestOwnedSource(retained.fd, expected: snapshot)
            stage = "attach owned image read-only"
            let response = try run(["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", image.path])
            stage = "parse owned attach device"
            guard let root = try PropertyListSerialization.propertyList(from: response, format: nil) as? [String: Any],
                  let entities = root["system-entities"] as? [[String: Any]],
                  let wholeDisk = entities.compactMap({ $0["dev-entry"] as? String }).first(where: Self.isWholeDisk) else {
                throw InstallerUseReadError.unavailable("The owned fixture attach response was ambiguous; retain it.")
            }
            disk = wholeDisk
            stage = "verify immutable source bytes and adopt own-attach ctime"
            // Native hdiutil attach updates source ctime on supported CI hosts.
            // Only this known fixture-owned step may adopt it, after proving
            // every other snapshot field and all held-source bytes unchanged.
            try anchor.validate()
            let attached = try InstallerFileAccess.snapshot(retained.fd)
            guard snapshot.matchesCaptured(attached),
                  attached == (try InstallerFileAccess.snapshotAt(anchor.fd, image.lastPathComponent)) else {
                throw InstallerUseReadError.unavailable("Own attach changed source fields beyond ctime: \(Self.changedFields(snapshot, attached)).")
            }
            guard try Self.digestOwnedSource(retained.fd, expected: attached) == originalDigest else {
                throw InstallerUseReadError.unavailable("Own attach changed the held source bytes; retain the fixture.")
            }
            try anchor.validate()
            guard attached == (try InstallerFileAccess.snapshotAt(anchor.fd, image.lastPathComponent)) else {
                throw InstallerUseReadError.unavailable("The owned source path changed during post-attach byte verification.")
            }
            sourceSnapshot = attached
            try verifyOwnedContent()
            _ = try imageIdentity()
        } catch {
            throw InstallerUseReadError.unavailable("Owned mount fixture failed at \(stage): \(error). \(sourceStateDiagnostics())")
        }
    }

    /// Observe why cleanup may retain the image after an unsuccessful attach.
    /// Field names only: this cannot adopt a new snapshot or authorize cleanup.
    private func sourceStateDiagnostics() -> String {
        guard let sourceAnchor, let retainedSource, let sourceSnapshot else {
            return "Owned source diagnostic: retention-not-established"
        }
        let anchorValid: Bool
        do { try sourceAnchor.validate(); anchorValid = true }
        catch { anchorValid = false }
        let held = try? InstallerFileAccess.snapshot(retainedSource.fd)
        let named = try? InstallerFileAccess.snapshotAt(sourceAnchor.fd, image.lastPathComponent)
        let heldFields = held.map { Self.changedFields(sourceSnapshot, $0) } ?? "unreadable"
        let namedFields = named.map { Self.changedFields(sourceSnapshot, $0) } ?? "unreadable"
        return "Owned source diagnostic: anchorValid=\(anchorValid) heldChanged=\(heldFields) namedChanged=\(namedFields)"
    }

    func useTarget() throws -> InstallerUseTarget {
        let identity = try imageIdentity()
        guard let retainedSource else { throw InstallerUseReadError.unavailable("The owned source handle is missing.") }
        return .init(device: identity.device, inode: identity.inode, path: image.path,
                     observerRetainedFileDescriptors: [retainedSource.fd])
    }

    func imageIdentity() throws -> InstallerUseFileIdentity {
        var info = stat()
        guard let sourceAnchor, let retainedSource, let sourceSnapshot else {
            throw InstallerUseReadError.unavailable("The owned source retention snapshot is missing.")
        }
        do { try sourceAnchor.validate() }
        catch { throw InstallerUseReadError.unavailable("The owned source directory anchor changed: \(error)") }
        let held: InstallerFileSnapshot, path: InstallerFileSnapshot
        do { held = try InstallerFileAccess.snapshot(retainedSource.fd) }
        catch { throw InstallerUseReadError.unavailable("The held owned source snapshot could not be read: \(error)") }
        do { path = try InstallerFileAccess.snapshotAt(sourceAnchor.fd, image.lastPathComponent) }
        catch { throw InstallerUseReadError.unavailable("The owned source path snapshot could not be read: \(error)") }
        guard sourceSnapshot == held, sourceSnapshot == path else {
            throw InstallerUseReadError.unavailable("Owned source snapshot fields changed; held=\(Self.changedFields(sourceSnapshot, held)), path=\(Self.changedFields(sourceSnapshot, path)).")
        }
        guard lstat(image.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(),
              let expected = createdImageIdentity,
              expected == (try InstallerUseNativeParsing.identity(at: image)) else {
            throw InstallerUseReadError.unavailable("The owned image source changed.")
        }
        return expected
    }

    func record(in data: Data) throws -> [String: Any] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else {
            throw InstallerUseReadError.unavailable("Invalid real disk-image inventory.")
        }
        let physicalPath = image.resolvingSymlinksInPath().path
        let matches = images.filter {
            guard let path = $0["image-path"] as? String, path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == physicalPath
        }
        guard matches.count == 1, let match = matches.first else {
            let deviceMatches = images.filter {
                guard let entities = $0["system-entities"] as? [[String: Any]], let disk else { return false }
                return entities.contains { ($0["dev-entry"] as? String) == disk }
            }
            // Counts/types only: never log another image's path, alias or data.
            let candidateAlias = deviceMatches.first?["image-alias"]
            let candidateAliasType = candidateAlias.map { String(reflecting: type(of: $0)) } ?? "missing"
            throw InstallerUseReadError.unavailable("Owned mount selection failed: images=\(images.count), physicalPathMatches=\(matches.count), capturedDeviceMatches=\(deviceMatches.count), candidateAliasType=\(candidateAliasType).")
        }
        // Fixture-only provenance: the source was created by this test and
        // pinned before attach. Production must never infer an arbitrary
        // mounted source's original identity from its reported path.
        guard let reportedPath = match["image-path"] as? String,
              try InstallerUseNativeParsing.identity(at: URL(fileURLWithPath: reportedPath)) == imageIdentity() else {
            let shape = match.keys.sorted().prefix(48).map { key in
                "\(key):\(String(reflecting: type(of: match[key]!)))"
            }.joined(separator: "; ")
            throw InstallerUseReadError.unavailable("The owned fixture source path/held identity disagrees. Owned-record shape: \(shape)")
        }
        return match
    }

    /// Exercises the real pre-rename device guard with the already owned,
    /// read-only mounted marker. No additional mount or mutable image is needed.
    func verifyCrossDeviceMoveRefused() async throws {
        try verifyOwnedContent()
        let data = try await InstallerDiskImageInventory.shared.read(deadline: ProcessInfo.processInfo.systemUptime + 15)
        let imageRecord = try record(in: data)
        guard let disk, let destination = sourceAnchor,
              let entities = imageRecord["system-entities"] as? [[String: Any]],
              entities.contains(where: { ($0["dev-entry"] as? String) == disk }) else {
            throw InstallerUseReadError.unavailable("The cross-device fixture's owned source/device could not be verified.")
        }
        let mounts = entities.compactMap { $0["mount-point"] as? String }
        guard mounts.count == 1, let mount = mounts.first,
              URL(fileURLWithPath: mount).lastPathComponent == volume else {
            throw InstallerUseReadError.unavailable("The cross-device fixture's unique mounted volume could not be verified.")
        }
        let source = try InstallerDirectoryAnchor.open(URL(fileURLWithPath: mount, isDirectory: true))
        let retainedMarker = try InstallerFileDescriptor(parent: source, name: marker.lastPathComponent)
        let before = try InstallerFileAccess.snapshot(retainedMarker.fd)
        var filesystem = statfs()
        guard before.mode & UInt32(S_IFMT) == UInt32(S_IFREG), before.links == 1,
              before == (try InstallerFileAccess.snapshotAt(source.fd, marker.lastPathComponent)),
              fstatfs(source.fd, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_RDONLY) != 0,
              source.identity.device != destination.identity.device,
              before.device == source.identity.device else {
            throw InstallerUseReadError.unavailable("The owned cross-device fixture is not a pinned read-only source on a different device.")
        }
        try requireMountedMarkerBytes(retainedMarker.fd)
        let destinationName = "cross-device-refusal.txt"
        try InstallerFileAccess.assertAbsent(destination, destinationName)
        var rejection: InstallerTrashFailure?
        do {
            try InstallerFileAccess.exclusiveMove(from: source, name: marker.lastPathComponent,
                                                 to: destination, destinationName: destinationName)
        } catch let failure as InstallerTrashFailure { rejection = failure }
        guard rejection == .unsupportedRename else {
            throw InstallerUseReadError.unavailable("The actual cross-device move did not reject with unsupportedRename.")
        }
        try source.validate()
        try destination.validate()
        guard before == (try InstallerFileAccess.snapshot(retainedMarker.fd)),
              before == (try InstallerFileAccess.snapshotAt(source.fd, marker.lastPathComponent)) else {
            throw InstallerUseReadError.unavailable("The owned mounted marker changed during cross-device refusal.")
        }
        try requireMountedMarkerBytes(retainedMarker.fd)
        try InstallerFileAccess.assertAbsent(destination, destinationName)
        try verifyOwnedContent()
        _ = try imageIdentity()
    }

    private func requireMountedMarkerBytes(_ fd: Int32) throws {
        var bytes = [UInt8](repeating: 0, count: markerBytes.count + 1)
        let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count == markerBytes.count, Data(bytes.prefix(markerBytes.count)) == markerBytes else {
            throw InstallerUseReadError.unavailable("The pinned mounted fixture marker bytes do not match the authored marker.")
        }
    }

    func detachAndRemove() async throws {
        if cleaned { return }
        try verifyOwnedContent()
        if let disk {
            let data = try await InstallerDiskImageInventory.shared.read(deadline: ProcessInfo.processInfo.systemUptime + 15)
            let imageRecord = try record(in: data)
            guard let entities = imageRecord["system-entities"] as? [[String: Any]],
                  entities.contains(where: { ($0["dev-entry"] as? String) == disk }),
                  let mount = entities.compactMap({ $0["mount-point"] as? String }).first,
                  URL(fileURLWithPath: mount).lastPathComponent == volume,
                  try Data(contentsOf: URL(fileURLWithPath: mount).appendingPathComponent(marker.lastPathComponent)) == markerBytes else {
                throw InstallerUseReadError.unavailable("The fresh image/device/volume marker disagrees; retain the fixture.")
            }
            _ = try imageIdentity()
            _ = try run(["detach", disk]) // Never -force, never an unverified/reused device.
            self.disk = nil
            try await verifyFixtureDetached(returnedDevice: disk)
        } else if createdImageIdentity != nil {
            // An ambiguous attach can leave an unrecorded device. A newly read
            // inventory must show that this exact fixture source is not attached.
            let data = try await InstallerDiskImageInventory.shared.read(deadline: ProcessInfo.processInfo.systemUptime + 15)
            guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let images = root["images"] as? [[String: Any]],
                  !images.contains(where: {
                      guard let path = $0["image-path"] as? String else { return true }
                      return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == image.resolvingSymlinksInPath().path
                  }) else {
                throw InstallerUseReadError.unavailable("The fixture may remain attached; retain it.")
            }
        }
        try verifyOwnedContent()
        // Remove exact, checked regular files and then empty directories. Never
        // recursively delete a directory with unexpected children.
        if createdImageIdentity != nil {
            _ = try imageIdentity()
            guard unlink(image.path) == 0 else { throw InstallerUseReadError.unavailable("Retain fixture image after cleanup failure.") }
        }
        guard unlink(marker.path) == 0, rmdir(content.path) == 0, rmdir(root.path) == 0 else {
            throw InstallerUseReadError.unavailable("Retain fixture after exact-member cleanup failed.")
        }
        cleaned = true
    }

    private func verifyFixtureDetached(returnedDevice: String) async throws {
        let data = try await InstallerDiskImageInventory.shared.read(deadline: ProcessInfo.processInfo.systemUptime + 15)
        guard let inventory = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = inventory["images"] as? [[String: Any]] else {
            throw InstallerUseReadError.unavailable("The fixture detach result could not be read; retain the source.")
        }
        for record in images {
            guard let path = record["image-path"] as? String,
                  let entities = record["system-entities"] as? [[String: Any]] else {
                throw InstallerUseReadError.unavailable("An incomplete image record prevents fixture detach verification.")
            }
            guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path != image.path,
                  !entities.contains(where: { ($0["dev-entry"] as? String) == returnedDevice }) else {
                throw InstallerUseReadError.unavailable("The fixture source/device is still attached; retain it.")
            }
        }
        _ = try imageIdentity()
    }

    private func verifyOwnedContent() throws {
        var rootStat = stat(), contentStat = stat(), markerStat = stat()
        guard lstat(root.path, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR,
              lstat(content.path, &contentStat) == 0, (contentStat.st_mode & S_IFMT) == S_IFDIR,
              lstat(marker.path, &markerStat) == 0, (markerStat.st_mode & S_IFMT) == S_IFREG,
              try InstallerUseNativeParsing.identity(at: root) == rootIdentity,
              try InstallerUseNativeParsing.identity(at: content) == contentIdentity,
              try InstallerUseNativeParsing.identity(at: marker) == markerIdentity,
              try Data(contentsOf: marker) == markerBytes,
              Set(try FileManager.default.contentsOfDirectory(atPath: content.path)) == [marker.lastPathComponent],
              Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).isSubset(of: ["content", "owned.dmg"]) else {
            throw InstallerUseReadError.unavailable("The fixture marker/root/members changed; retain it.")
        }
    }

    private static func changedFields(_ a: InstallerFileSnapshot, _ b: InstallerFileSnapshot) -> String {
        var fields: [String] = []
        if a.device != b.device { fields.append("device") }
        if a.inode != b.inode { fields.append("inode") }
        if a.mode != b.mode { fields.append("mode") }
        if a.uid != b.uid || a.gid != b.gid { fields.append("ownership") }
        if a.links != b.links { fields.append("linkCount") }
        if a.flags != b.flags { fields.append("flags") }
        if a.bytes != b.bytes { fields.append("size") }
        if a.modifiedSeconds != b.modifiedSeconds || a.modifiedNanoseconds != b.modifiedNanoseconds { fields.append("mtime") }
        if a.changedSeconds != b.changedSeconds || a.changedNanoseconds != b.changedNanoseconds { fields.append("ctime") }
        return fields.isEmpty ? "none" : fields.joined(separator: ",")
    }

    private static func digestOwnedSource(_ fd: Int32, expected: InstallerFileSnapshot) throws -> [UInt8] {
        guard expected.bytes > 0, expected.bytes <= 64 * 1_024 * 1_024,
              expected == (try InstallerFileAccess.snapshot(fd)) else {
            throw InstallerUseReadError.unavailable("The owned image is outside its byte budget or changed before hashing.")
        }
        var hash = SHA256(), offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < expected.bytes {
            let wanted = Int(min(Int64(buffer.count), expected.bytes - offset))
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, wanted, off_t(offset)) }
            guard count > 0, count <= wanted else {
                throw InstallerUseReadError.unavailable("The entire owned image could not be hashed.")
            }
            hash.update(data: Data(buffer.prefix(count)))
            offset += Int64(count)
        }
        var extra: UInt8 = 0
        guard pread(fd, &extra, 1, off_t(offset)) == 0,
              expected == (try InstallerFileAccess.snapshot(fd)) else {
            throw InstallerUseReadError.unavailable("The owned image changed while hashing.")
        }
        return Array(hash.finalize())
    }

    private static func isWholeDisk(_ value: String) -> Bool {
        value.hasPrefix("/dev/disk") && !value.dropFirst(9).isEmpty
            && value.dropFirst(9).allSatisfy({ $0.isASCII && $0.isNumber })
    }

    private func run(_ arguments: [String]) throws -> Data {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let readers = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        defer { for reader in readers { try? reader.close() } }
        // Drain both streams together so diagnostic stderr can never block the
        // child behind a full pipe. Memory remains bounded, even on failure.
        for reader in readers {
            let flags = fcntl(reader.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(reader.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw InstallerUseReadError.unavailable("The owned fixture diagnostic pipe could not be configured.")
            }
        }
        try process.run()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        var descriptors = readers.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0) }
        var output = Data(), diagnostic = InstallerFixtureCommandDiagnostics()
        var overflow = false, readFailure = false
        var exitedAt: TimeInterval?
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while descriptors.contains(where: { $0.fd >= 0 }) {
            if !process.isRunning {
                if exitedAt == nil { exitedAt = ProcessInfo.processInfo.systemUptime }
                // A descendant-held diagnostic pipe must not stall this test.
                if ProcessInfo.processInfo.systemUptime - (exitedAt ?? 0) > 2 { break }
            }
            let ready = descriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), 100)
            }
            if ready < 0 {
                if errno == EINTR { continue }
                readFailure = true; break
            }
            for index in descriptors.indices where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptors[index].fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    if index == 0 {
                        if !overflow && count <= 2 * 1_024 * 1_024 - output.count { output.append(contentsOf: buffer.prefix(count)) }
                        else { overflow = true }
                    } else { diagnostic.append(buffer.prefix(count)) }
                } else if count == 0 { descriptors[index].fd = -1 }
                else if errno != EINTR && errno != EAGAIN {
                    readFailure = true; descriptors[index].fd = -1
                }
            }
        }
        process.waitUntilExit()
        let complete = !descriptors.contains(where: { $0.fd >= 0 }) && !readFailure
        guard process.terminationReason == .exit, process.terminationStatus == 0, !overflow, complete else {
            // Only fixed categories and numeric/boolean fields are emitted.
            // Never expose raw stderr, command arguments, paths or plist bytes.
            throw InstallerUseReadError.unavailable("The owned DMG fixture system operation did not complete. reason=\(process.terminationReason.rawValue) status=\(process.terminationStatus) stdoutOverflow=\(overflow) streamsComplete=\(complete) \(diagnostic.summary)")
        }
        return output
    }
}

private enum InstallerUseCIFixtureGate {
    static func enabled(_ flag: String) -> Bool {
        ProcessInfo.processInfo.environment[flag] == "1"
    }

    /// Bounded diagnostic counts only. Never emit another image's source path,
    /// mounted volume path, bookmark data or arbitrary string values.
    static func imageCountDiagnostics() async -> String {
        do {
            let bytes = try await InstallerDiskImageInventory.shared.read(deadline: ProcessInfo.processInfo.systemUptime + 3)
            guard let root = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  let images = root["images"] as? [[String: Any]] else { return "Image inventory diagnostic: malformed root/images type" }
            var fixtureNamed = 0, simulatorLocated = 0, pathMissing = 0
            for record in images {
                guard let path = record["image-path"] as? String else { pathMissing += 1; continue }
                if URL(fileURLWithPath: path).pathComponents.contains(where: { component in
                    let prefix = "MoeKit-owned-dmg-"
                    return component.hasPrefix(prefix) && UUID(uuidString: String(component.dropFirst(prefix.count))) != nil
                }) { fixtureNamed += 1 }
                if path.hasPrefix("/Library/Developer/CoreSimulator/Images/")
                    || path.hasPrefix("/Library/Developer/CoreSimulator/Profiles/Runtimes/") { simulatorLocated += 1 }
            }
            return "Image inventory counts: total=\(images.count), fixtureNamedSources=\(fixtureNamed), simulatorLocatedSources=\(simulatorLocated), missingSourcePath=\(pathMissing)"
        } catch { return "Image inventory counts could not be read: \(error)" }
    }

    /// Foundation can present /private/var through its /var alias. Strict
    /// no-follow directory anchors need the actual native physical path.
    static func physicalTemporaryDirectory() throws -> URL {
        var destination = [CChar](repeating: 0, count: Int(PATH_MAX))
        let succeeded = FileManager.default.temporaryDirectory.path.withCString { source in
            destination.withUnsafeMutableBufferPointer { realpath(source, $0.baseAddress) != nil }
        }
        guard succeeded else { throw InstallerUseReadError.unavailable("The owned fixture temporary base could not be physically resolved.") }
        let path = destination.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func requireHostedRunner() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted" else {
            throw InstallerUseReadError.unavailable("An opted-in native fixture requires a verified ephemeral GitHub-hosted runner; the fixture did not run.")
        }
    }
}


/// Test-only fixed-category diagnostics. Original bytes never become log text.
private struct InstallerFixtureCommandDiagnostics {
    static let maximumBytes = 8_192
    private(set) var prefix = Data()
    private(set) var truncated = false
    private(set) var observedByteCount = 0
    mutating func append(_ bytes: ArraySlice<UInt8>) {
        let (total, overflow) = observedByteCount.addingReportingOverflow(bytes.count)
        observedByteCount = overflow ? Int.max : total
        let available = Self.maximumBytes - prefix.count
        prefix.append(contentsOf: bytes.prefix(available))
        if bytes.count > available { truncated = true }
    }
    var category: String {
        guard !prefix.isEmpty else { return "empty" }
        let text = String(decoding: prefix, as: UTF8.self).lowercased()
        let patterns: [(String, [String])] = [
            ("resource-busy", ["resource busy"]),
            ("resource-temporarily-unavailable", ["resource temporarily unavailable"]),
            ("operation-timed-out", ["operation timed out", "operation timeout"]),
            ("permission-denied", ["permission denied", "operation not permitted"]),
            ("no-mountable-filesystem", ["no mountable file systems"]),
            ("device-unavailable", ["device not configured", "no such device"]),
            ("file-not-found", ["no such file or directory"]),
            ("out-of-space", ["no space left on device"]),
            ("out-of-memory", ["cannot allocate memory", "not enough memory"]),
            ("descriptor-limit", ["too many open files"]),
            ("read-only-filesystem", ["read-only file system"]),
            ("file-exists", ["file exists"]),
            ("authentication-error", ["authentication error", "authentication failed"]),
            ("unsupported-operation", ["operation not supported", "function not implemented"]),
            ("input-output", ["input/output error", "i/o error"]),
            ("invalid-format", ["not recognized", "invalid argument"]),
            ("corrupt-image", ["corrupt image"]),
            ("checksum", ["checksum"]),
        ]
        return patterns.first { $0.1.contains { text.contains($0) } }?.0 ?? "unclassified"
    }

    /// Only a newline-terminated, exact hdiutil failure template yields an Int32 hint.
    /// This is not an errno interpretation; paths, arbitrary strings and numeric
    /// substrings from other messages are never emitted. Truncated tails cannot
    /// become apparently complete diagnostic lines.
    var numericHint: Int32? {
        let bytes = Array(prefix)
        var lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
        if bytes.last != 10 { _ = lines.popLast() }
        for line in lines {
            guard let text = String(bytes: line, encoding: .utf8) else { continue }
            for operation in ["create", "attach", "detach"] {
                for label in ["Unknown error ", "Error "] {
                    let header = "hdiutil: \(operation) failed - \(label)"
                    guard text.hasPrefix(header) else { continue }
                    let suffix = text.dropFirst(header.count)
                    let digits = suffix.first == "-" ? suffix.dropFirst() : suffix[...]
                    guard !digits.isEmpty, digits.count <= 10,
                          digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                          let value = Int32(suffix) else { continue }
                    return value
                }
            }
        }
        return nil
    }

    var summary: String {
        let hint = numericHint.map(String.init) ?? "none"
        return "stderrCategory=\(category) stderrNumericHint=\(hint) stderrUnknown=\(category == "unclassified") stderrBytes=\(observedByteCount) stderrTruncated=\(truncated)"
    }
}

extension InstallerUseEvidenceTests {
    @Test func boundsAndCategoriesNeverReturnOriginalBytes() {
        for (text, category) in [("hdiutil: attach failed - Resource busy", "resource-busy"),
                                 ("private fixture: Operation not permitted", "permission-denied"),
                                 ("attach failed - no mountable file systems", "no-mountable-filesystem"),
                                 ("private path unknown message", "unclassified"), ("", "empty")] {
            var diagnostic = InstallerFixtureCommandDiagnostics()
            diagnostic.append(Array(text.utf8)[...])
            #expect(diagnostic.category == category)
            #expect(!diagnostic.truncated)
        }
        var bounded = InstallerFixtureCommandDiagnostics()
        bounded.append(Array(repeating: UInt8(65), count: 20_000)[...])
        #expect(bounded.prefix.count == 8_192 && bounded.truncated)
        #expect(bounded.category == "unclassified")
        bounded.append(Array("Resource busy".utf8)[...])
        #expect(bounded.prefix.count == 8_192 && bounded.category == "unclassified")
        #expect(bounded.observedByteCount == 20_013)
    }

    @Test func fixtureFailureDiagnosticsRemainFixedAndBounded() {
        for (message, category) in [
            ("Resource temporarily unavailable", "resource-temporarily-unavailable"),
            ("Operation timed out", "operation-timed-out"),
            ("Authentication error", "authentication-error"),
            ("No such file or directory", "file-not-found"),
            ("No space left on device", "out-of-space"),
            ("Too many open files", "descriptor-limit"),
            ("Read-only file system", "read-only-filesystem"),
            ("corrupt image", "corrupt-image")
        ] {
            var diagnostic = InstallerFixtureCommandDiagnostics()
            diagnostic.append(Array("hdiutil: attach failed - \(message)\n".utf8)[...])
            #expect(diagnostic.category == category)
            #expect(diagnostic.numericHint == nil)
        }
        let privateText = "/Users/Private Person/keychain secret\n/private/var/owned.dmg \"token\"\u{1b}[31m\u{202e}\nrelative/secret.dmg"
        var unknown = InstallerFixtureCommandDiagnostics()
        unknown.append(Array(privateText.utf8)[...])
        #expect(unknown.summary == "stderrCategory=unclassified stderrNumericHint=none stderrUnknown=true stderrBytes=\(privateText.utf8.count) stderrTruncated=false")
    }

    @Test func numericFixtureHintsRequireExactCompleteTemplates() {
        for value in [Int32.min, -1, 0, 49153, Int32.max] {
            var diagnostic = InstallerFixtureCommandDiagnostics()
            diagnostic.append(Array("hdiutil: attach failed - Unknown error \(value)\n".utf8)[...])
            #expect(diagnostic.numericHint == value)
        }
        for text in ["hdiutil: attach failed - Unknown error 2147483648\n",
                     "hdiutil: attach failed - Unknown error 12",
                     "hdiutil: attach failed - Unknown error -2147483649\n",
                     "hdiutil: attach failed - Unknown error １２\n",
                     "hdiutil: attach failed - Unknown error +12\n",
                     "hdiutil: attach failed - Unknown error 12 /private/secret\n",
                     "hdiutil: attach failed - Unknown error /private/12\n",
                     "private hdiutil: attach failed - Unknown error 12\n",
                     "hdiutil: unrelated failed - Unknown error 12\n"] {
            var diagnostic = InstallerFixtureCommandDiagnostics()
            diagnostic.append(Array(text.utf8)[...])
            #expect(diagnostic.numericHint == nil)
        }
        let tail = "hdiutil: attach failed - Unknown error 12"
        var truncated = InstallerFixtureCommandDiagnostics()
        truncated.append(Array((String(repeating: "x", count: InstallerFixtureCommandDiagnostics.maximumBytes - tail.utf8.count - 1) + "\n" + tail + "private").utf8)[...])
        #expect(truncated.truncated && truncated.numericHint == nil)
    }
}
