import Foundation

protocol DockerCleanupExecuting: Sendable {
    func inspect(endpoint: DockerEndpoint, cancellation: DockerCancellation) async throws -> DockerInventory
    func prepare(inventory: DockerInventory, selection: DockerSelection, cancellation: DockerCancellation) async throws -> DockerCleanupPlan
    func execute(plan: DockerCleanupPlan, cancellation: DockerCancellation) async throws -> DockerCleanupResult
    func discardPlans() async
}

actor NativeDockerCleanupExecutor: DockerCleanupExecuting {
    private let transport: any DockerTransport
    private let now: @Sendable () -> Date
    private var pendingPlan: DockerCleanupPlan?
    init(transport: any DockerTransport = DockerSocketTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    func inspect(endpoint: DockerEndpoint, cancellation: DockerCancellation) async throws -> DockerInventory {
        pendingPlan = nil
        let transport = transport, now = now
        return try await Task.detached { try DockerEngineSession(transport: transport, now: now).inventory(endpoint, cancellation) }.value
    }

    func prepare(inventory: DockerInventory, selection: DockerSelection, cancellation: DockerCancellation) async throws -> DockerCleanupPlan {
        pendingPlan = nil
        guard !selection.isEmpty else { throw DockerCleanupError.invalidSelection }
        let transport = transport, now = now
        let fresh = try await Task.detached {
            try DockerEngineSession(transport: transport, now: now).inventory(inventory.daemon.endpoint, cancellation)
        }.value
        try DockerEngineSession.validate(selection, original: inventory, fresh: fresh)
        try cancellation.check()
        let plan = DockerCleanupPlan(id: UUID(), inventory: fresh, selection: selection, expiresAt: now().addingTimeInterval(60))
        pendingPlan = plan
        return plan
    }

    func execute(plan: DockerCleanupPlan, cancellation: DockerCancellation) async throws -> DockerCleanupResult {
        guard let approved = pendingPlan, approved.id == plan.id else { throw DockerCleanupError.alreadyConsumed }
        pendingPlan = nil // consume before suspension; no replay, automatic retry or duplicate click
        guard approved.expiresAt > now() else { throw DockerCleanupError.expired }
        let transport = transport, now = now
        return try await Task.detached {
            try DockerEngineSession(transport: transport, now: now).execute(approved, cancellation)
        }.value
    }

    func discardPlans() { pendingPlan = nil }
}

/// Only this session builds request paths. No incoming URL, daemon message or label becomes an action.
struct DockerEngineSession: Sendable {
    let transport: any DockerTransport
    let now: @Sendable () -> Date

    private struct Version: Decodable {
        let ApiVersion: String
        let MinAPIVersion: String?
    }
    private struct Info: Decodable {
        let ID: String
        let Name: String
        let ServerVersion: String
        let OperatingSystem: String
        let OSType: String
        let SecurityOptions: [String]?
    }
    private struct DiskUsage: Decodable {
        let Images: [DockerImage]?
        let Volumes: [DockerVolume]?
        let BuildCache: [DockerBuildCache]?
        enum CodingKeys: String, CodingKey { case Images, Volumes, BuildCache }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.Images), container.contains(.Volumes), container.contains(.BuildCache) else {
                throw DockerCleanupError.malformedResponse
            }
            Images = try container.decodeIfPresent([DockerImage].self, forKey: .Images)
            Volumes = try container.decodeIfPresent([DockerVolume].self, forKey: .Volumes)
            BuildCache = try container.decodeIfPresent([DockerBuildCache].self, forKey: .BuildCache)
        }
    }
    private struct Prune: Decodable {
        let CachesDeleted: [String]?
        let SpaceReclaimed: UInt64
    }

    func inventory(_ endpoint: DockerEndpoint, _ cancellation: DockerCancellation) throws -> DockerInventory {
        try cancellation.check()
        let socket = try transport.identity(for: endpoint)
        let version: Version = try read(endpoint, socket, "/version", cancellation)
        guard let maximum = apiMinor(version.ApiVersion), maximum >= 44,
              let minimum = apiMinor(version.MinAPIVersion ?? "1.24"), minimum <= 44 else { throw DockerCleanupError.unsupportedDaemon }
        let info: Info = try read(endpoint, socket, "/v1.44/info", cancellation)
        guard !info.ID.isEmpty, info.ID.utf8.count <= 256, info.OSType == "linux" else { throw DockerCleanupError.unsupportedDaemon }
        let disk: DiskUsage = try read(endpoint, socket, "/v1.44/system/df", cancellation)
        let containers: [DockerContainer] = try read(endpoint, socket, "/v1.44/containers/json?all=1", cancellation)
        let after: Info = try read(endpoint, socket, "/v1.44/info", cancellation)
        guard info.ID == after.ID, info.Name == after.Name, info.ServerVersion == after.ServerVersion,
              try transport.identity(for: endpoint) == socket else { throw DockerCleanupError.changed }
        let images = disk.Images ?? [], volumes = disk.Volumes ?? [], cache = disk.BuildCache ?? []
        guard images.count <= 20_000, containers.count <= 20_000, volumes.count <= 20_000, cache.count <= 20_000,
              Set(images.map(\.id)).count == images.count, Set(containers.map(\.id)).count == containers.count,
              Set(volumes.map(\.id)).count == volumes.count, Set(cache.map(\.id)).count == cache.count,
              images.allSatisfy({ DockerValidation.imageID($0.id) }),
              containers.allSatisfy({ DockerValidation.containerID($0.id) && DockerValidation.imageID($0.imageID) }) else {
            throw DockerCleanupError.malformedResponse
        }
        return DockerInventory(id: UUID(), capturedAt: now(), daemon: DockerDaemonIdentity(
            endpoint: endpoint, socket: socket, id: info.ID, name: info.Name, version: info.ServerVersion,
            operatingSystem: info.OperatingSystem, rootless: info.SecurityOptions?.contains(where: { $0 == "name=rootless" }) == true),
            images: images, containers: containers, volumes: volumes, buildCache: cache)
    }

    static func validate(_ selection: DockerSelection, original: DockerInventory, fresh: DockerInventory) throws {
        guard original.daemon == fresh.daemon else { throw DockerCleanupError.changed }
        for id in selection.imageIDs {
            guard let before = original.images.first(where: { $0.id == id }),
                  let current = fresh.images.first(where: { $0.id == id }),
                  before.id == current.id, before.tags == current.tags, before.created == current.created, before.labels == current.labels,
                  fresh.imageIsEligible(current) else { throw DockerCleanupError.changed }
        }
        for id in selection.containerIDs {
            guard DockerValidation.containerID(id), let before = original.containers.first(where: { $0.id == id }),
                  let current = fresh.containers.first(where: { $0.id == id }), before == current,
                  current.isStopped else { throw DockerCleanupError.changed }
        }
        if selection.allUnusedBuildCache {
            guard !fresh.buildCache.filter({ !$0.inUse }).isEmpty,
                  Set(original.buildCache.map(\.id)) == Set(fresh.buildCache.map(\.id)),
                  original.buildCache.allSatisfy({ before in fresh.buildCache.contains(before) }) else { throw DockerCleanupError.changed }
        }
    }

    func execute(_ plan: DockerCleanupPlan, _ cancellation: DockerCancellation) throws -> DockerCleanupResult {
        try cancellation.check()
        let initial = try inventory(plan.inventory.daemon.endpoint, cancellation)
        try Self.validate(plan.selection, original: plan.inventory, fresh: initial)
        guard now() < plan.expiresAt else { throw DockerCleanupError.expired }
        var items: [DockerCleanupResult.Item] = []
        var reclaimed: UInt64?
        let targets = plan.selection.containerIDs.sorted().map { (kind: "container", id: $0) } +
            plan.selection.imageIDs.sorted().map { (kind: "image", id: $0) } +
            (plan.selection.allUnusedBuildCache ? [(kind: "cache", id: "all-unused-build-cache")] : [])
        var shouldStop = false
        for target in targets {
            if shouldStop || cancellation.isCancelled {
                items.append(.init(id: target.id, state: .skipped, detail: "Not sent to Docker."))
                continue
            }
            do {
                // Each mutation gets fresh daemon and complete container-reference evidence.
                let fresh = try inventory(plan.inventory.daemon.endpoint, cancellation)
                var single = DockerSelection()
                if target.kind == "container" { single.containerIDs = [target.id] }
                if target.kind == "image" { single.imageIDs = [target.id] }
                if target.kind == "cache" { single.allUnusedBuildCache = true }
                try Self.validate(single, original: plan.inventory, fresh: fresh)
                guard now() < plan.expiresAt else { throw DockerCleanupError.expired }
                let response: DockerHTTPResponse
                if target.kind == "cache" {
                    // This is intentionally a separately disclosed whole-unused-cache action.
                    response = try transport.request(endpoint: fresh.daemon.endpoint, identity: fresh.daemon.socket,
                        method: "POST", path: "/v1.44/build/prune?all=true", cancellation: cancellation)
                } else {
                    let path = target.kind == "image"
                        ? "/v1.44/images/\(target.id)?force=false&noprune=true"
                        : "/v1.44/containers/\(target.id)?force=false&v=false"
                    response = try transport.request(endpoint: fresh.daemon.endpoint, identity: fresh.daemon.socket,
                        method: "DELETE", path: path, cancellation: cancellation)
                }
                guard (200...299).contains(response.status) else { throw DockerCleanupError.daemon(response.status) }
                if target.kind == "cache" {
                    let report = try JSONDecoder().decode(Prune.self, from: response.body)
                    reclaimed = report.SpaceReclaimed
                }
                // A successful HTTP status is not yet treated as verified removal.
                items.append(.init(id: target.id, state: .uncertain, detail: "Docker accepted the operation; verification pending."))
            } catch {
                let explicitRefusal: Bool
                if case DockerCleanupError.daemon(let status) = error { explicitRefusal = (400...499).contains(status) }
                else { explicitRefusal = error as? DockerCleanupError == .changed || error as? DockerCleanupError == .invalidSelection }
                items.append(.init(id: target.id, state: explicitRefusal ? .failed : .uncertain,
                                   detail: (error as? LocalizedError)?.errorDescription ?? "Docker operation could not be verified."))
                // Do not continue after ambiguity, cancellation, identity change or partial failure.
                shouldStop = true
            }
        }
        // Cancellation stops further mutation, but a new bounded read checks already-sent operations.
        // This token is intentionally independent; closing a socket does not roll back Docker.
        let verified = try? inventory(plan.inventory.daemon.endpoint, DockerCancellation())
        let final = verified?.daemon == plan.inventory.daemon ? verified : nil
        if let final {
            items = items.map { item in
                guard item.state != .skipped else { return item }
                if plan.selection.imageIDs.contains(item.id), !final.images.contains(where: { $0.id == item.id }) {
                    return .init(id: item.id, state: .removed, detail: "Image ID is absent from the refreshed inventory.")
                }
                if plan.selection.containerIDs.contains(item.id), !final.containers.contains(where: { $0.id == item.id }) {
                    return .init(id: item.id, state: .removed, detail: "Container ID is absent. Its volumes were not requested for removal.")
                }
                if item.id == "all-unused-build-cache", reclaimed != nil {
                    let before = Set(plan.inventory.buildCache.filter { !$0.inUse }.map(\.id))
                    let remaining = before.intersection(Set(final.buildCache.map(\.id)))
                    return .init(id: item.id, state: remaining.isEmpty ? .removed : .retained,
                                 detail: "Build-cache pruning finished. The refreshed inventory shows which records remain; shared or newly in-use cache may be retained.")
                }
                if item.state == .uncertain {
                    return .init(id: item.id, state: .retained, detail: "Object is still present. No automatic retry was made.")
                }
                return item
            }
        }
        return DockerCleanupResult(items: items, inventory: final, cancelled: cancellation.isCancelled, reclaimedCacheBytes: reclaimed)
    }

    private func read<T: Decodable>(_ endpoint: DockerEndpoint, _ socket: DockerSocketIdentity, _ path: String,
                                    _ cancellation: DockerCancellation) throws -> T {
        let response = try transport.request(endpoint: endpoint, identity: socket, method: "GET", path: path, cancellation: cancellation)
        guard response.status == 200 else { throw DockerCleanupError.daemon(response.status) }
        do { return try JSONDecoder().decode(T.self, from: response.body) }
        catch { throw DockerCleanupError.malformedResponse }
    }
    private func apiMinor(_ value: String) -> Int? {
        let parts = value.split(separator: ".")
        guard parts.count == 2, parts[0] == "1" else { return nil }
        return Int(parts[1])
    }
}
