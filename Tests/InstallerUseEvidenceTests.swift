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
        Issue.record("Real current-user file-use coverage never completed within 25 seconds; source activation remains blocked. Last cause: \(latest)")
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
            try await fixture.detachAndRemove()
            try InstallerNativeFixtureEvidence.record(kind: "mounted-image", detail: [
                "sourceDevice": String(source.device), "sourceInode": String(source.inode),
                "result": "verified-attach-and-detach", "observedRefusal": "true"
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
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MoeKit-installer-use-\(token)", isDirectory: true)
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
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MoeKit-owned-dmg-\(token)", isDirectory: true)
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
        try verifyOwnedContent()
        guard Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["content"] else {
            throw InstallerUseReadError.unavailable("Unexpected fixture member before image creation; retain it.")
        }
        _ = try run(["create", "-srcfolder", content.path, "-volname", volume, "-format", "UDZO", image.path])
        let anchor = try InstallerDirectoryAnchor.open(root)
        let retained = try InstallerFileDescriptor(parent: anchor, name: image.lastPathComponent)
        let snapshot = try InstallerFileAccess.snapshot(retained.fd)
        guard snapshot == (try InstallerFileAccess.snapshotAt(anchor.fd, image.lastPathComponent)) else {
            throw InstallerUseReadError.unavailable("The owned source changed before its retention handle was established.")
        }
        sourceAnchor = anchor
        retainedSource = retained
        sourceSnapshot = snapshot
        createdImageIdentity = .init(device: snapshot.device, inode: snapshot.inode)
        try verifyOwnedContent()
        _ = try imageIdentity()
        let response = try run(["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", image.path])
        guard let root = try PropertyListSerialization.propertyList(from: response, format: nil) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]],
              let wholeDisk = entities.compactMap({ $0["dev-entry"] as? String }).first(where: Self.isWholeDisk) else {
            throw InstallerUseReadError.unavailable("The owned fixture attach response was ambiguous; retain it.")
        }
        disk = wholeDisk
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
        try sourceAnchor.validate()
        guard sourceSnapshot == (try InstallerFileAccess.snapshot(retainedSource.fd)),
              sourceSnapshot == (try InstallerFileAccess.snapshotAt(sourceAnchor.fd, image.lastPathComponent)),
              lstat(image.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
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

    private static func isWholeDisk(_ value: String) -> Bool {
        value.hasPrefix("/dev/disk") && !value.dropFirst(9).isEmpty
            && value.dropFirst(9).allSatisfy({ $0.isASCII && $0.isNumber })
    }

    private func run(_ arguments: [String]) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? pipe.fileHandleForWriting.close()
        defer { try? pipe.fileHandleForReading.close() }
        var output = Data(), overflow = false
        while let bytes = try pipe.fileHandleForReading.read(upToCount: 16_384), !bytes.isEmpty {
            if bytes.count <= 2 * 1_024 * 1_024 - output.count && !overflow { output.append(bytes) }
            else { overflow = true }
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0, !overflow else {
            throw InstallerUseReadError.unavailable("The owned DMG fixture system operation did not complete.")
        }
        return output
    }
}

private enum InstallerUseCIFixtureGate {
    static func enabled(_ flag: String) -> Bool {
        ProcessInfo.processInfo.environment[flag] == "1"
    }

    static func requireHostedRunner() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted" else {
            throw InstallerUseReadError.unavailable("An opted-in native fixture requires a verified ephemeral GitHub-hosted runner; the fixture did not run.")
        }
    }
}
