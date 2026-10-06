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
    let socket = DockerSocketIdentity(path: "/fixture/owned.sock", device: 1, inode: 2, owner: 501)

    func identity(for endpoint: DockerEndpoint) throws -> DockerSocketIdentity { socket }
    func request(endpoint: DockerEndpoint, identity: DockerSocketIdentity, method: String, path: String,
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
        var demo = true
        store.bindContext { demo }
        store.inspect()
        #expect(transport.counts().requests == 0)
        #expect(!store.canInspect)
        demo = false
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
        var demo = false
        store.bindContext { demo }
        store.inspect()
        for _ in 0..<1_000 where store.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        store.select(DockerSelection(imageIDs: [dockerImageA])); store.prepare()
        for _ in 0..<1_000 where store.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        let plan = try #require(store.plan)
        demo = true // deliberately before onChange could synchronize the UI
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
        #expect(fd >= 0)
        defer { _ = close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketURL.path.utf8) + [UInt8(0)]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(chmod(socketURL.path, 0o600) == 0)
        #expect(listen(fd, 1) == 0)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: socketURL)
        let endpoint = DockerEndpoint(name: "Owned fixture", socketPath: alias.path)
        let transport = DockerSocketTransport(timeout: 2)
        let identity = try transport.identity(for: endpoint)
        #expect(identity.path == socketURL.resolvingSymlinksInPath().path)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { completed.signal() }
            var wait = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&wait, 1, 3_000) > 0 else { return }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }
            defer { _ = close(connection) }
            var buffer = [UInt8](repeating: 0, count: 2048)
            _ = recv(connection, &buffer, buffer.count, 0)
            let response = Array("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
            _ = response.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
        }
        let response = try transport.request(endpoint: endpoint, identity: identity, method: "GET", path: "/version", cancellation: DockerCancellation())
        #expect(response.status == 200)
        #expect(response.body == Data("{}".utf8))
        #expect(completed.wait(timeout: .now() + 4) == .success)
    }
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
