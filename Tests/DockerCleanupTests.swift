import Foundation
import Testing
@testable import MoeKit

private let dockerImageA = "sha256:" + String(repeating: "a", count: 64)
private let dockerImageB = "sha256:" + String(repeating: "b", count: 64)
private let dockerContainerA = String(repeating: "c", count: 64)

/// All responses are in-memory fixtures. Never accesses a real daemon or Docker config.
private final class FixtureDockerTransport: DockerTransport, @unchecked Sendable {
    let lock = NSLock()
    var imageObjects: [[String: Any]] = []
    var containerObjects: [[String: Any]] = []
    var cacheObjects: [[String: Any]] = []
    var daemonID = "owned-fixture-daemon"
    var requests: [(String, String)] = []
    var refusal: Int?
    var loseConnectionAfterDelete = false
    var mutationCount = 0
    var ambiguousMutation = false
    var mutationGate: DockerFixtureGate?
    let peer = DockerPeerIdentity(pid: 321, uid: 501, gid: 20, processToken: [321, 1])
    let socket = DockerSocketIdentity(path: "/fixture/owned.sock", device: 1, inode: 2, owner: 501)

    func identity(for endpoint: DockerEndpoint) throws -> DockerSocketIdentity { socket }
    func peerIdentity(endpoint: DockerEndpoint, identity: DockerSocketIdentity, cancellation: DockerCancellation) throws -> DockerPeerIdentity { peer }
    func request(endpoint: DockerEndpoint, identity: DockerSocketIdentity, peer: DockerPeerIdentity, method: String, path: String,
                 cancellation: DockerCancellation) throws -> DockerHTTPResponse {
        lock.lock(); defer { lock.unlock() }
        try cancellation.check()
        requests.append((method, path))
        if loseConnectionAfterDelete && mutationCount > 0 { throw DockerCleanupError.timeout }
        var body: Any = [:]
        if method == "GET" {
            switch path {
            case "/version": body = ["ApiVersion": "1.48", "MinAPIVersion": "1.24"]
            case "/v1.44/info": body = ["ID": daemonID, "Name": "fixture", "ServerVersion": "28.0.0", "OperatingSystem": "Fixture", "OSType": "linux", "SecurityOptions": ["name=rootless"]] as [String: Any]
            case "/v1.44/system/df": body = ["Images": imageObjects, "Volumes": [["Name": "protected-volume", "Driver": "local"]], "BuildCache": cacheObjects]
            case "/v1.44/containers/json?all=1": body = containerObjects
            default: throw DockerCleanupError.malformedResponse
            }
        } else {
            mutationCount += 1
            mutationGate?.wait()
            if ambiguousMutation { throw DockerCleanupError.timeout }
            if let refusal { return DockerHTTPResponse(status: refusal, body: Data("{}".utf8)) }
            if path.hasPrefix("/v1.44/images/") {
                imageObjects.removeAll { path.contains($0["Id"] as? String ?? "missing") }
                body = [["Deleted": dockerImageA]]
            } else if path.hasPrefix("/v1.44/containers/") {
                containerObjects.removeAll { path.contains($0["Id"] as? String ?? "missing") }
            } else if path == "/v1.44/build/prune?all=true" {
                let ids = cacheObjects.filter { $0["InUse"] as? Bool == false }.compactMap { $0["ID"] as? String }
                cacheObjects.removeAll { $0["InUse"] as? Bool == false }
                body = ["CachesDeleted": ids, "SpaceReclaimed": 128] as [String: Any]
            } else { throw DockerCleanupError.invalidSelection }
        }
        return DockerHTTPResponse(status: method == "DELETE" && path.contains("containers/") ? 204 : 200,
                                  body: try JSONSerialization.data(withJSONObject: body))
    }
    func setImages(_ images: [[String: Any]]) { lock.lock(); imageObjects = images; lock.unlock() }
    func setContainers(_ values: [[String: Any]]) { lock.lock(); containerObjects = values; lock.unlock() }
    func setCache(_ values: [[String: Any]]) { lock.lock(); cacheObjects = values; lock.unlock() }
    func loseMutationResponse(gate: DockerFixtureGate? = nil) { lock.lock(); ambiguousMutation = true; mutationGate = gate; lock.unlock() }
    func setDaemon(_ id: String) { lock.lock(); daemonID = id; lock.unlock() }
    func setRefusal(_ value: Int) { lock.lock(); refusal = value; lock.unlock() }
    func disconnectAfterDelete() { lock.lock(); loseConnectionAfterDelete = true; lock.unlock() }
    func counts() -> (requests: Int, mutations: Int) { lock.lock(); defer { lock.unlock() }; return (requests.count, mutationCount) }
}

private func imageJSON(_ id: String = dockerImageA, containers: Int = 0, tags: [String] = []) -> [String: Any] {
    ["Id": id, "RepoTags": tags, "Size": 300, "SharedSize": 100, "Containers": containers, "Created": 42,
     "Labels": ["com.docker.compose.project": "fixture-project", "private-label": "not displayed"]] as [String: Any]
}
private func containerJSON(state: String = "exited", image: String = dockerImageA) -> [String: Any] {
    ["Id": dockerContainerA, "ImageID": image, "Names": ["/owned-container"], "State": state, "Created": 43, "Labels": [:]] as [String: Any]
}
private func cacheJSON(id: String, inUse: Bool) -> [String: Any] {
    ["ID": id, "InUse": inUse, "Shared": false, "Size": 128] as [String: Any]
}

@Suite("Docker exact-scope cleanup")
struct DockerCleanupTests {
    let endpoint = DockerEndpoint(name: "Fixture", socketPath: "/fixture/owned.sock")

    @Test func initializationIsInert() async {
        let transport = FixtureDockerTransport()
        _ = NativeDockerCleanupExecutor(transport: transport)
        #expect(transport.counts().requests == 0)
    }
    @Test func stoppedContainerProtectsImage() async throws {
        let transport = FixtureDockerTransport()
        transport.setImages([imageJSON()]) // independent container listing wins over inconsistent count
        transport.setContainers([containerJSON()])
        let engine = NativeDockerCleanupExecutor(transport: transport)
        let inventory = try await engine.inspect(endpoint: endpoint, cancellation: DockerCancellation())
        #expect(!inventory.imageIsEligible(inventory.images[0]))
        #expect(inventory.containers[0].isStopped)
        #expect(inventory.images[0].labels["private-label"] == nil)
        #expect(inventory.images[0].uniqueBytes == 200)
        await #expect(throws: DockerCleanupError.self) {
            _ = try await engine.prepare(inventory: inventory, selection: DockerSelection(imageIDs: [dockerImageA]), cancellation: DockerCancellation())
        }
        #expect(transport.counts().mutations == 0)
    }
    @Test(arguments: ["running", "paused", "restarting", "dead", "removing", "unknown"])
    func activeAndUnknownStatesProtected(_ state: String) throws {
        let container = try JSONDecoder().decode(DockerContainer.self, from: JSONSerialization.data(withJSONObject: containerJSON(state: state)))
        #expect(!container.isStopped)
    }
    @Test func exactSelectionDeletesAndVerifiesOnlySelectedIDs() async throws {
        let transport = FixtureDockerTransport()
        transport.setImages([imageJSON(), imageJSON(dockerImageB)])
        let engine = NativeDockerCleanupExecutor(transport: transport)
        let inventory = try await engine.inspect(endpoint: endpoint, cancellation: DockerCancellation())
        let plan = try await engine.prepare(inventory: inventory, selection: DockerSelection(imageIDs: [dockerImageA]), cancellation: DockerCancellation())
        let result = try await engine.execute(plan: plan, cancellation: DockerCancellation())
        #expect(result.items.map(\.state) == [.removed])
        #expect(result.inventory?.images.map(\.id) == [dockerImageB])
        #expect(result.inventory?.volumes.map(\.name) == ["protected-volume"])
        #expect(transport.counts().mutations == 1)
        await #expect(throws: DockerCleanupError.alreadyConsumed) { _ = try await engine.execute(plan: plan, cancellation: DockerCancellation()) }
    }
    @Test func newStoppedReferenceBlocksOldConfirmation() async throws {
        let transport = FixtureDockerTransport(); transport.setImages([imageJSON()])
        let engine = NativeDockerCleanupExecutor(transport: transport)
        let inventory = try await engine.inspect(endpoint: endpoint, cancellation: DockerCancellation())
        let plan = try await engine.prepare(inventory: inventory, selection: DockerSelection(imageIDs: [dockerImageA]), cancellation: DockerCancellation())
        transport.setContainers([containerJSON()])
        await #expect(throws: DockerCleanupError.changed) { _ = try await engine.execute(plan: plan, cancellation: DockerCancellation()) }
        #expect(transport.counts().mutations == 0)
    }
    @Test func changedDaemonBlocksOldConfirmation() async throws {
        let transport = FixtureDockerTransport(); transport.setImages([imageJSON()])
        let engine = NativeDockerCleanupExecutor(transport: transport)
        let inventory = try await engine.inspect(endpoint: endpoint, cancellation: DockerCancellation())
        let plan = try await engine.prepare(inventory: inventory, selection: DockerSelection(imageIDs: [dockerImageA]), cancellation: DockerCancellation())
        transport.setDaemon("replacement")
        await #expect(throws: DockerCleanupError.changed) { _ = try await engine.execute(plan: plan, cancellation: DockerCancellation()) }
        #expect(transport.counts().mutations == 0)
    }
    @Test func selectedStoppedContainerRemovedVolumesRetained() async throws {
        let transport = FixtureDockerTransport(); transport.setContainers([containerJSON()])
        let engine = NativeDockerCleanupExecutor(transport: transport)
        let inventory = try await engine.inspect(endpoint: endpoint, cancellation: DockerCancellation())
        let plan = try await engine.prepare(inventory: inventory, selection: DockerSelection(containerIDs: [dockerContainerA]), cancellation: DockerCancellation())
        let result = try await engine.execute(plan: plan, cancellation: DockerCancellation())
        #expect(result.items.map(\.state) == [.removed])
        #expect(result.inventory?.containers.isEmpty == true)
        #expect(result.inventory?.volumes.count == 1)
    }
    @Test func cacheScopeIsExplicitAndInUseCacheSurvives() async throws {
        let transport = FixtureDockerTransport(); transport.setCache([cacheJSON(id: "unused", inUse: false), cacheJSON(id: "used", inUse: true)])
        let engine = NativeDockerCleanupExecutor(transport: transport)
        let inventory = try await engine.inspect(endpoint: endpoint, cancellation: DockerCancellation())
        let plan = try await engine.prepare(inventory: inventory, selection: DockerSelection(allUnusedBuildCache: true), cancellation: DockerCancellation())
        let result = try await engine.execute(plan: plan, cancellation: DockerCancellation())
        #expect(result.inventory?.buildCache.map(\.id) == ["used"])
        #expect(result.reclaimedCacheBytes == 128)
        #expect(result.items.map(\.state) == [.removed])
    }
    @Test func refusalStopsRemainingMutations() async throws {
        let transport = FixtureDockerTransport(); transport.setImages([imageJSON(), imageJSON(dockerImageB)])
        let engine = NativeDockerCleanupExecutor(transport: transport)
        let inventory = try await engine.inspect(endpoint: endpoint, cancellation: DockerCancellation())
        let plan = try await engine.prepare(inventory: inventory, selection: DockerSelection(imageIDs: [dockerImageA, dockerImageB]), cancellation: DockerCancellation())
        transport.setRefusal(409)
        let result = try await engine.execute(plan: plan, cancellation: DockerCancellation())
        #expect(result.items.map(\.state) == [.failed, .skipped])
        #expect(transport.counts().mutations == 1)
    }
    @Test func lostConnectionNeverClaimsSuccess() async throws {
        let transport = FixtureDockerTransport(); transport.setImages([imageJSON()])
        let engine = NativeDockerCleanupExecutor(transport: transport)
        let inventory = try await engine.inspect(endpoint: endpoint, cancellation: DockerCancellation())
        let plan = try await engine.prepare(inventory: inventory, selection: DockerSelection(imageIDs: [dockerImageA]), cancellation: DockerCancellation())
        transport.disconnectAfterDelete()
        let result = try await engine.execute(plan: plan, cancellation: DockerCancellation())
        #expect(result.hasUncertainty)
        #expect(result.items.map(\.state) == [.uncertain])
        #expect(result.inventory == nil)
    }
    @Test func cancelledBeforeMutationIsInert() async throws {
        let transport = FixtureDockerTransport(); transport.setImages([imageJSON()])
        let engine = NativeDockerCleanupExecutor(transport: transport)
        let inventory = try await engine.inspect(endpoint: endpoint, cancellation: DockerCancellation())
        let plan = try await engine.prepare(inventory: inventory, selection: DockerSelection(imageIDs: [dockerImageA]), cancellation: DockerCancellation())
        let cancellation = DockerCancellation(); cancellation.cancel()
        await #expect(throws: DockerCleanupError.cancelled) { _ = try await engine.execute(plan: plan, cancellation: cancellation) }
        #expect(transport.counts().mutations == 0)
    }
    @Test func transportAllowlistRejectsBroadOrRemoteActions() {
        #expect(!DockerSocketTransport.allowed(method: "POST", path: "/v1.44/system/prune"))
        #expect(!DockerSocketTransport.allowed(method: "POST", path: "/v1.44/volumes/prune"))
        #expect(!DockerSocketTransport.allowed(method: "GET", path: "https://remote/info"))
        #expect(!DockerSocketTransport.allowed(method: "DELETE", path: "/v1.44/images/tag?force=true"))
        #expect(!DockerSocketTransport.allowed(method: "POST", path: "/v1.44/images/create?fromImage=alpine"))
        #expect(!DockerSocketTransport.allowed(method: "GET", path: "/v1.44/containers/\(dockerContainerA)/json"))
        #expect(DockerSocketTransport.allowed(method: "DELETE", path: "/v1.44/images/\(dockerImageA)?force=false&noprune=true"))
    }
    @Test func httpFramingIsBoundedAndStrict() throws {
        let valid = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        #expect(try DockerHTTPParser.parse(valid, maximumBodyBytes: 10).body == Data("{}".utf8))
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n".utf8)
        #expect(try DockerHTTPParser.parse(chunked, maximumBodyBytes: 10).body == Data("{}".utf8))
        #expect(throws: DockerCleanupError.responseTooLarge) { _ = try DockerHTTPParser.parse(valid, maximumBodyBytes: 1) }
        #expect(throws: DockerCleanupError.malformedResponse) { _ = try DockerHTTPParser.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}".utf8), maximumBodyBytes: 10) }
        #expect(throws: DockerCleanupError.malformedResponse) { _ = try DockerHTTPParser.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}".utf8), maximumBodyBytes: 10) }
    }
}

@Suite("Docker controller and Demo boundaries") @MainActor
struct DockerCleanupStoreTests {
    @Test func openingAndDemoNeverConnect() async throws {
        let transport = FixtureDockerTransport()
        let store = DockerCleanupStore(executor: NativeDockerCleanupExecutor(transport: transport))
        let demo = DockerDemoFixtureState(enabled: true)
        store.bindContext { demo.enabled }
        store.inspect()
        #expect(transport.counts().requests == 0)
        #expect(!store.canInspect)
        demo.enabled = false
        store.updateDemo(false)
        #expect(store.canInspect)
        #expect(transport.counts().requests == 0)
    }
    @Test func preparationIsReadOnlyAndDismissPreventsExecution() async throws {
        let transport = FixtureDockerTransport(); transport.setImages([imageJSON()])
        let store = DockerCleanupStore(executor: NativeDockerCleanupExecutor(transport: transport))
        store.inspect()
        for _ in 0..<1_000 where store.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        #expect(store.inventory != nil)
        store.select(DockerSelection(imageIDs: [dockerImageA]))
        store.prepare()
        for _ in 0..<1_000 where store.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        let plan = try #require(store.plan)
        #expect(transport.counts().mutations == 0)
        store.dismissPlan()
        store.confirm(planID: plan.id)
        #expect(transport.counts().mutations == 0)
    }
    @Test func immediateDemoSwitchBlocksConfirmation() async throws {
        let transport = FixtureDockerTransport(); transport.setImages([imageJSON()])
        let store = DockerCleanupStore(executor: NativeDockerCleanupExecutor(transport: transport))
        let demo = DockerDemoFixtureState(enabled: false)
        store.bindContext { demo.enabled }
        store.inspect()
        for _ in 0..<1_000 where store.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        store.select(DockerSelection(imageIDs: [dockerImageA])); store.prepare()
        for _ in 0..<1_000 where store.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        let plan = try #require(store.plan)
        demo.enabled = true // deliberately before onChange could synchronize the UI
        store.confirm(planID: plan.id)
        #expect(transport.counts().mutations == 0)
        #expect(store.inventory == nil)
        #expect(store.plan == nil)
    }
}

#if canImport(Darwin)
import Darwin

@Suite("Docker native local socket adapter")
struct DockerSocketAdapterTests {
    @Test func rejectsRegularFileWithoutOpeningIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moekit-docker-socket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-socket")
        try Data("owned fixture".utf8).write(to: file)
        let endpoint = DockerEndpoint(name: "Owned fixture", socketPath: file.path)
        #expect(throws: DockerCleanupError.unsafeSocket) { _ = try DockerSocketTransport().identity(for: endpoint) }
    }
    @Test func nativeSocketAndDesktopStyleSymlinkResolveToExactIdentity() throws {
        // /tmp keeps sockaddr_un below its 104-byte macOS path limit.
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("mk-docker-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("daemon.sock")
        let alias = directory.appendingPathComponent("desktop.sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0, "Owned socket creation failed, errno \(errno)")
        defer { _ = close(fd) }
        try #require(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, "Listener close-on-exec failed, errno \(errno)")
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketURL.path.utf8) + [UInt8(0)]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0, "Owned bind failed, errno \(errno)")
        try #require(chmod(socketURL.path, 0o600) == 0, "Owned socket mode failed, errno \(errno)")
        try #require(listen(fd, 1) == 0, "Owned listen failed, errno \(errno)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: socketURL)
        let endpoint = DockerEndpoint(name: "Owned fixture", socketPath: alias.path)
        let transport = DockerSocketTransport(timeout: 2)
        let identity = try transport.identity(for: endpoint)
        #expect(identity.path == socketURL.resolvingSymlinksInPath().path)
        let expectedRequest = Data("GET /version HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
        let server = try DockerNativeSocketFixture(listener: fd, expectedRequest: expectedRequest)
        server.start()
        defer {
            // This runs on an early client throw too. The worker owns a dup, so
            // it can never accidentally poll an fd reused after the test closes fd.
            #expect(server.stopAndWait(), "Owned socket worker did not finish: \(server.snapshot)")
            print("Docker native socket fixture: \(server.snapshot)")
        }
        try server.waitReady()
        let peer = try server.client("peer probe") {
            try transport.peerIdentity(endpoint: endpoint, identity: identity, cancellation: DockerCancellation())
        }
        #expect(peer.pid == getpid())
        #expect(peer.uid == geteuid())
        // Deliberately queue the probe before allowing accept. With backlog 1,
        // the HTTP connection must not race an undrained closed probe.
        server.allowProbeDrain()
        try server.waitDrained(0)
        let response = try server.client("HTTP request") {
            try transport.request(endpoint: endpoint, identity: identity, peer: peer, method: "GET", path: "/version", cancellation: DockerCancellation())
        }
        #expect(response.status == 200)
        #expect(response.body == Data("{}".utf8))
        try server.waitDrained(1)
        let wrongPeer = DockerPeerIdentity(pid: peer.pid, uid: peer.uid, gid: peer.gid, processToken: peer.processToken + [0])
        #expect(throws: DockerCleanupError.changed) {
            try server.client("wrong-peer request", expectedError: .changed) {
                _ = try transport.request(endpoint: endpoint, identity: identity, peer: wrongPeer, method: "GET", path: "/version", cancellation: DockerCancellation())
            }
        }
        try server.waitDrained(2)
        #expect(server.receivedByteCounts == [0, expectedRequest.count, 0])
        // The connected peer check rejected the request before any HTTP bytes were sent.
        try FileManager.default.removeItem(at: alias)
        try Data("replacement is not a socket".utf8).write(to: alias)
        #expect(throws: DockerCleanupError.unsafeSocket) {
            _ = try transport.request(endpoint: endpoint, identity: identity, peer: peer, method: "GET", path: "/version", cancellation: DockerCancellation())
        }
    }
}

/// Test-only server. The accept gate forces the formerly racy backlog ordering;
/// per-connection acknowledgements prove EOF/framing and close before reconnect.
private final class DockerNativeSocketFixture: @unchecked Sendable {
    private let listener: Int32
    private let expectedRequest: Data
    private let ready = DispatchSemaphore(value: 0)
    private let acceptProbe = DispatchSemaphore(value: 0)
    private let drained = (0..<3).map { _ in DispatchSemaphore(value: 0) }
    private let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false
    private var finished = false
    private var failure: String?
    private var events: [String] = []
    private var counts: [Int] = []

    init(listener: Int32, expectedRequest: Data) throws {
        let owned = dup(listener)
        guard owned >= 0 else { throw DockerSocketFixtureFailure(stage: "dup listener", code: errno) }
        guard fcntl(owned, F_SETFL, O_NONBLOCK) == 0, fcntl(owned, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno; _ = close(owned)
            throw DockerSocketFixtureFailure(stage: "nonblocking listener", code: code)
        }
        self.listener = owned; self.expectedRequest = expectedRequest
    }
    var snapshot: String { lock.lock(); defer { lock.unlock() }; return events.joined(separator: " | ") }
    var receivedByteCounts: [Int] { lock.lock(); defer { lock.unlock() }; return counts }
    private func record(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    private func check(_ stage: String) throws {
        lock.lock(); let cancelled = stopped; lock.unlock()
        if cancelled { throw DockerSocketFixtureFailure(stage: stage + " cancelled", code: ECANCELED) }
    }
    func start() {
        DispatchQueue.global().async { [self] in
            defer {
                _ = close(listener)
                lock.lock(); finished = true; lock.unlock()
                // Release waiters on failure too; they check failure before proceeding.
                ready.signal(); drained.forEach { $0.signal() }; completed.signal()
            }
            do {
                record("server ready; accept gated"); ready.signal()
                guard acceptProbe.wait(timeout: .now() + 3) == .success else {
                    throw DockerSocketFixtureFailure(stage: "probe accept gate", code: ETIMEDOUT)
                }
                for index in 0..<3 {
                    try check("connection \(index)")
                    let count = try serve(index)
                    lock.lock(); counts.append(count); events.append("connection \(index) closed; received \(count) bytes"); lock.unlock()
                    drained[index].signal()
                }
            } catch {
                lock.lock(); failure = String(describing: error); events.append("server failure: \(error)"); lock.unlock()
            }
        }
    }
    func waitReady() throws { try waitFor(ready, stage: "server ready") }
    func allowProbeDrain() { record("probe returned; allow accept"); acceptProbe.signal() }
    func waitDrained(_ index: Int) throws { try waitFor(drained[index], stage: "connection \(index) drained") }
    private func waitFor(_ semaphore: DispatchSemaphore, stage: String) throws {
        guard semaphore.wait(timeout: .now() + 3) == .success else {
            throw DockerSocketFixtureFailure(stage: stage + "; " + snapshot, code: ETIMEDOUT)
        }
        lock.lock(); let error = failure; lock.unlock()
        if let error { throw DockerSocketFixtureFailure(stage: stage + "; " + error, code: 0) }
    }
    func stopAndWait() -> Bool {
        lock.lock(); stopped = true; let done = finished; lock.unlock()
        acceptProbe.signal()
        return done || completed.wait(timeout: .now() + 4) == .success
    }
    func client<T>(_ stage: String, expectedError: DockerCleanupError? = nil, _ action: () throws -> T) throws -> T {
        record("client " + stage)
        do { return try action() }
        catch {
            let observedErrno = errno // Snapshot only; production errors intentionally omit syscall details.
            if let expectedError, error as? DockerCleanupError == expectedError { throw error }
            throw DockerSocketFixtureFailure(stage: stage + ": \(error); thread errno snapshot=\(observedErrno); " + snapshot, code: 0)
        }
    }
    private func wait(_ descriptor: Int32, events: Int16, deadline: TimeInterval, stage: String) throws {
        while true {
            try check(stage)
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DockerSocketFixtureFailure(stage: stage, code: ETIMEDOUT) }
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&entry, 1, 100)
            if result < 0 { let code = errno; if code == EINTR { continue }; throw DockerSocketFixtureFailure(stage: stage, code: code) }
            if result > 0 {
                guard entry.revents & Int16(POLLNVAL) == 0 else { throw DockerSocketFixtureFailure(stage: stage, code: EBADF) }
                if entry.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
            }
        }
    }
    private func serve(_ index: Int) throws -> Int {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var connection: Int32 = -1
        while connection < 0 {
            try wait(listener, events: Int16(POLLIN), deadline: deadline, stage: "accept \(index)")
            connection = accept(listener, nil, nil)
            if connection < 0 {
                let code = errno
                if code == EINTR || code == EAGAIN { continue }
                throw DockerSocketFixtureFailure(stage: "accept \(index)", code: code)
            }
        }
        defer { _ = close(connection) }
        record("accepted connection \(index)")
        var noSignal: Int32 = 1
        guard fcntl(connection, F_SETFL, O_NONBLOCK) == 0, fcntl(connection, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw DockerSocketFixtureFailure(stage: "configure connection \(index)", code: errno)
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            try wait(connection, events: Int16(POLLIN), deadline: deadline, stage: "read \(index)")
            let count = recv(connection, &buffer, buffer.count, 0)
            if count < 0 {
                let code = errno
                if code == EAGAIN || code == EINTR { continue }
                throw DockerSocketFixtureFailure(stage: "read \(index)", code: code)
            }
            if count == 0 {
                guard index != 1, received.isEmpty else { throw DockerSocketFixtureFailure(stage: "unexpected EOF/data \(index)", code: 0) }
                return 0
            }
            received.append(contentsOf: buffer.prefix(count))
            guard index == 1, received.count <= 4096 else { throw DockerSocketFixtureFailure(stage: "unexpected/bounded request \(index)", code: 0) }
            if received.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard received == expectedRequest else { throw DockerSocketFixtureFailure(stage: "full HTTP request mismatch", code: 0) }
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
        var sent = 0
        while sent < response.count {
            try wait(connection, events: Int16(POLLOUT), deadline: deadline, stage: "write response")
            let count = response.withUnsafeBytes { send(connection, $0.baseAddress!.advanced(by: sent), $0.count - sent, 0) }
            if count < 0 {
                let code = errno
                if code == EAGAIN || code == EINTR { continue }
                throw DockerSocketFixtureFailure(stage: "write response", code: code)
            }
            guard count > 0 else { throw DockerSocketFixtureFailure(stage: "empty response write", code: 0) }
            sent += count
        }
        record("complete HTTP response sent")
        return received.count
    }
}

private struct DockerSocketFixtureFailure: Error, CustomStringConvertible {
    let stage: String
    let code: Int32
    var description: String { "Docker socket fixture: \(stage) (errno \(code))" }
}

#endif

private final class DockerFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
}

@Suite("Docker expiring authority")
struct DockerPlanExpiryTests {
    @Test func expiredPlanCannotSendMutation() async throws {
        let transport = FixtureDockerTransport(); transport.setImages([imageJSON()])
        let clock = DockerFixtureClock()
        let engine = NativeDockerCleanupExecutor(transport: transport, now: { clock.now() })
        let inventory = try await engine.inspect(endpoint: .init(name: "Fixture", socketPath: "/fixture/owned.sock"), cancellation: DockerCancellation())
        let plan = try await engine.prepare(inventory: inventory, selection: DockerSelection(imageIDs: [dockerImageA]), cancellation: DockerCancellation())
        clock.advance(61)
        await #expect(throws: DockerCleanupError.expired) { _ = try await engine.execute(plan: plan, cancellation: DockerCancellation()) }
        #expect(transport.counts().mutations == 0)
    }
}

@Suite("Docker controller full confirmation flow") @MainActor
struct DockerConfirmationFlowTests {
    @Test func duplicateConfirmSendsOneDeletionAndBlocksAppReplacement() async throws {
        let transport = FixtureDockerTransport(); transport.setImages([imageJSON()])
        let store = DockerCleanupStore(executor: NativeDockerCleanupExecutor(transport: transport))
        store.inspect()
        for _ in 0..<5_000 where store.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        store.select(DockerSelection(imageIDs: [dockerImageA])); store.prepare()
        for _ in 0..<5_000 where store.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        let plan = try #require(store.plan)
        #expect(transport.counts().mutations == 0)
        store.confirm(planID: plan.id)
        #expect(store.blocksAppUpdate)
        store.confirm(planID: plan.id)
        for _ in 0..<5_000 where store.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        #expect(transport.counts().mutations == 1)
        #expect(store.result?.items.first?.state == .removed)
        #expect(!store.blocksAppUpdate)
        #expect(store.selection.isEmpty)
    }
}

#if canImport(AppKit)
import AppKit
import SwiftUI
import XCTest

/// Owned view pixels and public layout anchors only; no desktop capture or live daemon.
final class DockerCleanupViewRenderTests: XCTestCase {
    @MainActor
    func testDockerStatesRenderWithoutLiveDaemon() async throws {
        let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
        XCTAssertTrue(["en", "zh-Hans"].contains(language))
        XCTAssertEqual(String(localized: "Docker cleanup", table: "DockerCleanup"), language == "zh-Hans" ? "Docker 清理" : "Docker cleanup")
        for scenario in ["first-use", "inventory", "verified-result", "uncertain-result", "demo"] {
            for dark in [false, true] {
                let transport = FixtureDockerTransport()
                transport.setImages([imageJSON()])
                let store = DockerCleanupStore(executor: NativeDockerCleanupExecutor(transport: transport))
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-docker-render-\(UUID())")
                let workspace = WorkspaceStore(isDemoEnabled: scenario == "demo", persistence: CatalogPersistence(directory: directory))
                if !["first-use", "demo"].contains(scenario) {
                    store.inspect(); try await settle(store)
                    if scenario.contains("result") {
                        store.select(DockerSelection(imageIDs: [dockerImageA])); store.prepare(); try await settle(store)
                        let plan = try XCTUnwrap(store.plan)
                        if scenario == "uncertain-result" { transport.disconnectAfterDelete() }
                        store.confirm(planID: plan.id); try await settle(store)
                    }
                }
                var required = ["docker.heading", "docker.connect"]
                if ["inventory", "verified-result"].contains(scenario) { required += ["docker.daemon", "docker.review"] }
                if scenario.contains("result") { required.append("docker.results") }
                if scenario == "demo" { required.append("docker.demo") }
                let size = NSSize(width: 980, height: 1600)
                let capture = DockerViewCapture()
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                _ = NSApplication.shared
                let previousAppearance = NSApp.appearance
                NSApp.appearance = appearance
                defer { NSApp.appearance = previousAppearance }
                let hosting = NSHostingView(rootView: DockerCleanupView(store: store).environment(workspace)
                    .environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, Locale.current)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .installerCaptureViewport().environment(\.installerCaptureCollector, { capture.regions = $0 }))
                hosting.sizingOptions = []; hosting.frame = NSRect(origin: .zero, size: size); hosting.appearance = appearance
                let window = DockerRenderWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = hosting
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                window.orderFront(nil)
                for _ in 0..<8 {
                    hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)); window.setContentSize(size)
                }
                let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)
                let visible = required.filter { id in capture.regions.contains {
                    $0.id == id && !$0.bounds.isEmpty && viewport.contains($0.bounds)
                } }
                let name = "docker-\(scenario)-\(language)-\(dark ? "dark" : "light")"
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                for x in [0, bitmap.pixelsWide / 2, bitmap.pixelsWide - 1] {
                    for y in [0, bitmap.pixelsHigh / 2, bitmap.pixelsHigh - 1] {
                        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0.99,
                                             "Owned window backing must be opaque")
                    }
                }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1000)
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name + ".png"; attachment.lifetime = .keepAlways; add(attachment)
                let metadata = XCTAttachment(string: """
                Exact synthetic scenario: \(scenario)
                Bundle language: \(language)
                In-memory API calls: \(transport.counts().requests)
                In-memory mutation calls: \(transport.counts().mutations)
                Real daemon requests: 0
                Scope: owned SwiftUI view rendering, not keyboard/VoiceOver acceptance.
                \(capture.regions.map { "\($0.id): \($0.bounds)" }.joined(separator: "\n"))
                """)
                metadata.name = name + "-scope.txt"; metadata.lifetime = .keepAlways; add(metadata)
                XCTAssertEqual(Set(visible), Set(required), "Missing/clipped Docker controls")
                if ["first-use", "demo"].contains(scenario) { XCTAssertEqual(transport.counts().requests, 0) }
                XCTAssertEqual(transport.counts().mutations, scenario.contains("result") ? 1 : 0)
            }
        }
    }
    @MainActor private func settle(_ store: DockerCleanupStore) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while store.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isBusy)
    }
}
@MainActor private final class DockerViewCapture { var regions: [InstallerCaptureRegion] = [] }
@MainActor private final class DockerRenderWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
#endif

@MainActor private final class DockerDemoFixtureState {
    var enabled: Bool
    init(enabled: Bool) { self.enabled = enabled }
}

private final class DockerFixtureGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    func wait() {
        condition.lock(); entered = true; condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }
    var hasEntered: Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

@Suite("Docker delayed mutation outcomes")
struct DockerDelayedOutcomeTests {
    @Test(arguments: ["image", "container", "cache"])
    func presenceCannotResolveLostMutationResponse(_ kind: String) async throws {
        let transport = FixtureDockerTransport()
        transport.setImages([imageJSON()])
        transport.setCache([cacheJSON(id: "pending-cache", inUse: false)])
        if kind == "container" { transport.setContainers([containerJSON(image: dockerImageB)]) }
        let engine = NativeDockerCleanupExecutor(transport: transport)
        let inventory = try await engine.inspect(endpoint: .init(name: "Fixture", socketPath: "/fixture/owned.sock"), cancellation: DockerCancellation())
        var selection = DockerSelection()
        if kind == "image" { selection.imageIDs = [dockerImageA] }
        if kind == "container" { selection.containerIDs = [dockerContainerA] }
        if kind == "cache" { selection.allUnusedBuildCache = true }
        let plan = try await engine.prepare(inventory: inventory, selection: selection, cancellation: DockerCancellation())
        transport.loseMutationResponse()
        let result = try await engine.execute(plan: plan, cancellation: DockerCancellation())
        #expect(result.inventory != nil) // reconnection succeeds, but the operation may still be pending
        #expect(result.hasUncertainty)
        #expect(result.items.map(\.state) == [.uncertain])
        #expect(transport.counts().mutations == 1)
    }
}

@Suite("Docker operation lifetime") @MainActor
struct DockerOperationLifetimeTests {
    @Test(arguments: [false, true])
    func navigationAndDemoRetainSentMutationOutcome(changeDemo: Bool) async throws {
        let transport = FixtureDockerTransport(); transport.setImages([imageJSON()])
        let gate = DockerFixtureGate()
        let store = DockerCleanupStore(executor: NativeDockerCleanupExecutor(transport: transport))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoeKit-docker-lifetime-\(UUID())")
        let workspace = WorkspaceStore(isDemoEnabled: false, persistence: CatalogPersistence(directory: directory), dockerCleanup: store)
        store.bindContext { [weak workspace] in workspace?.isDemoEnabled ?? true }
        store.inspect(); try await settle(store)
        store.select(DockerSelection(imageIDs: [dockerImageA])); store.prepare(); try await settle(store)
        let plan = try #require(store.plan)
        transport.loseMutationResponse(gate: gate)
        store.confirm(planID: plan.id)
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.hasEntered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.hasEntered)
        defer { gate.release() }
        store.leave() // Docker -> Caches; owner survives conditional view destruction
        #expect(workspace.dockerCleanup === store)
        #expect(store.blocksAppUpdate)
        if changeDemo { workspace.isDemoEnabled = true; #expect(store.inventory == nil) }
        gate.release()
        try await settle(store)
        #expect(!store.blocksAppUpdate)
        #expect(store.reports.count == 1)
        #expect(store.result?.hasUncertainty == true)
        if changeDemo {
            #expect(store.isDemoEnabled)
            #expect(store.inventory == nil) // real result was retained, never presented as demo inventory
            workspace.isDemoEnabled = false
        }
        // Docker view returns and an explicit refresh does not erase the unresolved operation.
        store.bindContext { [weak workspace] in workspace?.isDemoEnabled ?? true }
        let reportID = store.result?.id
        store.inspect(); try await settle(store)
        #expect(store.result?.id == reportID)
        #expect(store.result?.hasUncertainty == true)
        #expect(transport.counts().mutations == 1)
    }
    private func settle(_ store: DockerCleanupStore) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while store.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!store.isBusy)
    }
}

#if canImport(AppKit)
final class DockerConfirmationRenderTests: XCTestCase {
    @MainActor
    func testPermanentAndCacheConfirmationRenderAndReset() async throws {
        let language = try XCTUnwrap(Bundle.main.preferredLocalizations.first)
        for cacheScope in [false, true] {
            for dark in [false, true] {
                let transport = FixtureDockerTransport(); transport.setImages([imageJSON()])
                transport.setCache([cacheJSON(id: "owned-cache", inUse: false)])
                let executor = NativeDockerCleanupExecutor(transport: transport)
                let inventory = try await executor.inspect(endpoint: .init(name: "Owned fixture", socketPath: "/fixture/owned.sock"), cancellation: DockerCancellation())
                let plan = try await executor.prepare(inventory: inventory,
                    selection: DockerSelection(imageIDs: [dockerImageA], allUnusedBuildCache: cacheScope), cancellation: DockerCancellation())
                let acknowledgement = DockerConfirmationAcknowledgement()
                let callbacks = DockerConfirmationCallbacks()
                let size = NSSize(width: 720, height: 900)
                let capture = DockerViewCapture()
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                _ = NSApplication.shared
                let previousAppearance = NSApp.appearance
                NSApp.appearance = appearance
                defer { NSApp.appearance = previousAppearance }
                let hosting = NSHostingView(rootView: DockerCleanupConfirmationView(plan: plan, acknowledgement: acknowledgement,
                    onCancel: { callbacks.cancelled += 1 }, onConfirm: { callbacks.confirmed += 1 })
                    .environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, Locale.current)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .installerCaptureViewport().environment(\.installerCaptureCollector, { capture.regions = $0 }))
                hosting.sizingOptions = []; hosting.frame = NSRect(origin: .zero, size: size); hosting.appearance = appearance
                let window = DockerRenderWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = appearance; window.contentView = hosting
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                window.orderFront(nil)
                for _ in 0..<8 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)); window.setContentSize(size) }
                XCTAssertFalse(acknowledgement.canSubmit(plan))
                acknowledgement.submit(plan: plan) { callbacks.confirmed += 1 }
                XCTAssertEqual(callbacks.confirmed, 0)
                var required = ["docker.daemon", "docker.confirm.attestation", "docker.confirm.cancel", "docker.confirm.submit"]
                if cacheScope { required.append("docker.confirm.cache") }
                let viewport = CGRect(origin: .zero, size: size).insetBy(dx: -1, dy: -1)
                XCTAssertEqual(Set(required.filter { id in capture.regions.contains { $0.id == id && !$0.bounds.isEmpty && viewport.contains($0.bounds) } }), Set(required))
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                appearance.performAsCurrentDrawingAppearance { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
                for x in [0, bitmap.pixelsWide / 2, bitmap.pixelsWide - 1] {
                    for y in [0, bitmap.pixelsHigh / 2, bitmap.pixelsHigh - 1] {
                        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0.99,
                                             "Owned window backing must be opaque")
                    }
                }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "docker-confirm-\(cacheScope ? "whole-cache" : "exact")-\(language)-\(dark ? "dark" : "light").png"
                attachment.lifetime = .keepAlways; add(attachment)
                acknowledgement.irreversible = true
                XCTAssertEqual(acknowledgement.canSubmit(plan), !cacheScope)
                if cacheScope { acknowledgement.wholeCache = true }
                XCTAssertTrue(acknowledgement.canSubmit(plan))
                acknowledgement.submit(plan: plan) { callbacks.confirmed += 1 }
                acknowledgement.submit(plan: plan) { callbacks.confirmed += 1 }
                XCTAssertEqual(callbacks.confirmed, 1)
                acknowledgement.reset(for: plan.id)
                XCTAssertFalse(acknowledgement.irreversible)
                XCTAssertFalse(acknowledgement.wholeCache)
                XCTAssertFalse(acknowledgement.canSubmit(plan))
                acknowledgement.cancel { callbacks.cancelled += 1 }
                XCTAssertEqual(callbacks.cancelled, 1)
                XCTAssertFalse(acknowledgement.canSubmit(plan))
                XCTAssertEqual(transport.counts().mutations, 0) // callbacks never submit to even the synthetic engine
            }
        }
    }
}
#endif

@MainActor private final class DockerConfirmationCallbacks { var confirmed = 0; var cancelled = 0 }

@Suite("Docker terminal response contract")
struct DockerTerminalResponseTests {
    @Test(arguments: [201, 202, 206])
    func unexpectedSuccessStatusRemainsUncertain(_ status: Int) async throws {
        let transport = FixtureDockerTransport(); transport.setImages([imageJSON()])
        let executor = NativeDockerCleanupExecutor(transport: transport)
        let inventory = try await executor.inspect(endpoint: .init(name: "Fixture", socketPath: "/fixture/owned.sock"), cancellation: DockerCancellation())
        let plan = try await executor.prepare(inventory: inventory, selection: DockerSelection(imageIDs: [dockerImageA]), cancellation: DockerCancellation())
        transport.setRefusal(status)
        let result = try await executor.execute(plan: plan, cancellation: DockerCancellation())
        #expect(result.inventory != nil)
        #expect(result.items.map(\.state) == [.uncertain])
        #expect(result.hasUncertainty)
        #expect(transport.counts().mutations == 1)
    }
}
