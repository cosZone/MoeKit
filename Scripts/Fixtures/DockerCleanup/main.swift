import Foundation

struct FixtureManifest: Decodable {
    let marker: String
    let socket: String
    let unusedImage: String
    let stoppedImage: String
    let survivorImage: String
    let stoppedContainer: String
    let runningContainer: String
    let volume: String
}

@main struct DockerCleanupIntegration {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Owned fixture manifest required") }
        let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.marker == "MOEKIT_OWNED_DOCKER_FIXTURE_V1",
              manifestURL.path.hasPrefix("/tmp/moekit-docker-"),
              manifest.socket == manifestURL.deletingLastPathComponent().appendingPathComponent("daemon.sock").path else {
            fatalError("Refusing non-fixture daemon")
        }
        let engine = NativeDockerCleanupExecutor()
        let endpoint = DockerEndpoint(name: "Isolated CI fixture only", socketPath: manifest.socket)
        let initial = try await engine.inspect(endpoint: endpoint, cancellation: DockerCancellation())
        precondition(initial.containers.contains { $0.id == manifest.runningContainer && $0.state == "running" })
        precondition(initial.containers.contains { $0.id == manifest.stoppedContainer && $0.isStopped })
        precondition(initial.volumes.contains { $0.name == manifest.volume })
        let protectedImage = initial.images.first { $0.id == manifest.stoppedImage }!
        precondition(!initial.imageIsEligible(protectedImage), "Stopped container reference must protect its image")
        do {
            _ = try await engine.prepare(inventory: initial, selection: DockerSelection(imageIDs: [manifest.stoppedImage]), cancellation: DockerCancellation())
            fatalError("Referenced image was offered for deletion")
        } catch DockerCleanupError.changed { }

        let selected = DockerSelection(imageIDs: [manifest.unusedImage], containerIDs: [manifest.stoppedContainer])
        let plan = try await engine.prepare(inventory: initial, selection: selected, cancellation: DockerCancellation())
        let result = try await engine.execute(plan: plan, cancellation: DockerCancellation())
        precondition(result.items.count == 2 && result.items.allSatisfy { $0.state == .removed }, "Real selected deletion must be verified")
        let after = result.inventory!
        precondition(!after.images.contains { $0.id == manifest.unusedImage })
        precondition(!after.containers.contains { $0.id == manifest.stoppedContainer })
        precondition(after.images.contains { $0.id == manifest.stoppedImage }) // no automatic dependency deletion
        precondition(after.images.contains { $0.id == manifest.survivorImage })
        precondition(after.containers.contains { $0.id == manifest.runningContainer && $0.state == "running" })
        precondition(after.volumes.contains { $0.name == manifest.volume })
        do {
            _ = try await engine.execute(plan: plan, cancellation: DockerCancellation())
            fatalError("Consumed confirmation replayed")
        } catch DockerCleanupError.alreadyConsumed { }

        // Explicit whole-unused-cache scope is tested separately from selected object deletion.
        precondition(after.buildCache.contains { !$0.inUse }, "Fixture must provide real unused build cache")
        let cachePlan = try await engine.prepare(inventory: after, selection: DockerSelection(allUnusedBuildCache: true), cancellation: DockerCancellation())
        let cacheResult = try await engine.execute(plan: cachePlan, cancellation: DockerCancellation())
        precondition(cacheResult.reclaimedCacheBytes != nil, "Real cache API result required")
        let final = cacheResult.inventory!
        precondition(final.containers.contains { $0.id == manifest.runningContainer && $0.state == "running" })
        precondition(final.volumes.contains { $0.name == manifest.volume })
        precondition(final.images.contains { $0.id == manifest.survivorImage })
        let proof: [String: Any] = [
            "fixture": manifest.marker, "daemonID": initial.daemon.id,
            "selectedImageAbsent": true, "selectedStoppedContainerAbsent": true,
            "stoppedReferenceProtected": true, "unselectedImageRetained": true,
            "runningContainerRetained": true, "volumeRetained": true,
            "oneUseConfirmation": true, "cacheAPIExecuted": true,
            "cacheBytesReported": cacheResult.reclaimedCacheBytes!,
            "beforeCacheRecords": after.buildCache.count, "afterCacheRecords": final.buildCache.count,
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
