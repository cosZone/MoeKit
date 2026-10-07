import Foundation
import Testing
@testable import MoeKit

@MainActor @Suite("Mole online verification and untested consent")
struct MoleOnlineVerificationStoreTests {
    @Test("No online request on construction/discovery; explicit proof does not execute")
    func optInAndConsent() async throws {
        let discovery = OnlineDiscoveryFixture(), verifier = OnlineVerifierFixture(), executor = OnlineAnalysisFixture()
        let store = MoleAnalysisStore(executor: executor, discovery: discovery, homebrewVerifier: verifier)
        #expect(await verifier.count == 0)
        store.discoverIfNeeded(); await settle(store)
        #expect(await verifier.count == 0 && store.canVerifyHomebrewInstallation && store.executable == nil)
        store.verifyHomebrewInstallation(); await verifier.waitUntilStarted()
        store.verifyHomebrewInstallation()
        #expect(store.isVerifyingHomebrewInstallation && !store.canPrepare)
        #expect(await verifier.count == 1)
        await verifier.complete(); await settle(store)
        #expect(store.installation?.selectedCandidate?.issue == .untestedVersion)
        #expect(await executor.runCount == 0 && store.executable != nil)
        store.selectDirectory(URL(fileURLWithPath: "/Synthetic/folder"), ticket: try #require(store.selectionTicket()))
        store.prepare(); await settle(store)
        let id = try #require(store.plan?.id)
        #expect(store.plan?.release.requiresUntestedConsent == true)
        store.confirm(planID: id)
        #expect(await executor.runCount == 0 && store.plan?.id == id)
        store.confirm(planID: id, acknowledgeUntestedBuild: true)
        store.confirm(planID: id, acknowledgeUntestedBuild: true)
        await settle(store)
        #expect(await executor.runCount == 1)
    }

    @Test("A file or package change while online prevents accepting the proof")
    func changedDuringProof() async throws {
        let discovery = OnlineDiscoveryFixture(), verifier = OnlineVerifierFixture()
        let store = MoleAnalysisStore(discovery: discovery, homebrewVerifier: verifier)
        store.discoverIfNeeded(); await settle(store)
        store.verifyHomebrewInstallation(); await verifier.waitUntilStarted()
        await discovery.replaceIdentity()
        await verifier.complete(); await settle(store)
        #expect(store.executable == nil)
        #expect(store.installation?.selectedCandidate?.verifiedRelease == nil)
        #expect(store.errorMessage == MoleAnalysisFailure.changedSelection.errorDescription)
    }

    @Test("Online cancellation and rapid Demo round trip discard late proof")
    func cancellation() async throws {
        let discovery = OnlineDiscoveryFixture(), verifier = OnlineVerifierFixture()
        let store = MoleAnalysisStore(discovery: discovery, homebrewVerifier: verifier)
        store.discoverIfNeeded(); await settle(store)
        let ticket = try #require(store.selectionTicket())
        store.verifyHomebrewInstallation(); await verifier.waitUntilStarted()
        store.setDemoEnabled(true); store.setDemoEnabled(false)
        #expect(store.isBusy && store.isCancelling)
        await verifier.complete(); await settle(store)
        #expect(store.installation == nil && store.executable == nil)
        store.selectExecutable(URL(fileURLWithPath: "/Synthetic/old"), ticket: ticket)
        #expect(store.executable == nil)
    }

    @Test("A confirmed official mismatch stays modified/unverified, not missing")
    func modified() async throws {
        let discovery = OnlineDiscoveryFixture(), verifier = OnlineVerifierFixture()
        let store = MoleAnalysisStore(discovery: discovery, homebrewVerifier: verifier)
        store.discoverIfNeeded(); await settle(store)
        store.verifyHomebrewInstallation(); await verifier.waitUntilStarted()
        await verifier.fail(); await settle(store)
        #expect(store.installation?.selectedCandidate?.issue == .modifiedBuild)
        #expect(store.installation?.state == .unverified && store.executable == nil)
    }

    private func settle(_ store: MoleAnalysisStore) async {
        for _ in 0..<2000 { if !store.isBusy { return }; await Task.yield() }
        Issue.record("Mole verification state did not settle")
    }
}

private actor OnlineDiscoveryFixture: MoleInstallationDiscovering {
    private var inode: UInt64 = 2
    func replaceIdentity() { inode = 3 }
    func discover() async throws -> MoleInstallationReport {
        let observation = MoleAnalysisFiles.AnalyzerObservation(identity: .init(device: 1, inode: inode),
            byteCount: 16, sha256: String(repeating: "a", count: 64))
        return MoleInstallationReport(candidates: [MoleInstallationCandidate(
            path: "/Synthetic/Cellar/mole/1.59.0/libexec/bin/analyze-go", state: .unverified,
            source: "Homebrew", explanation: "Synthetic", declaredVersion: "1.59.0",
            origin: .homebrew(prefix: URL(fileURLWithPath: "/opt/homebrew")), issue: .unverifiedBuild,
            observation: observation, kegVersion: "1.59.0", isHomebrewCore: true)], inspectedAt: Date())
    }
}
private actor OnlineVerifierFixture: MoleHomebrewVerifying {
    var count = 0
    private var continuation: CheckedContinuation<MoleHomebrewEvidence, any Error>?
    func verify(expectedVersion: String, architecture: String, installedByteCount: Int, installedSHA256: String) async throws -> MoleHomebrewEvidence {
        count += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        for _ in 0..<2000 { if continuation != nil { return }; await Task.yield() }
        Issue.record("Online verifier did not start")
    }
    func complete() {
        let digest = String(repeating: "b", count: 64)
        continuation?.resume(returning: MoleHomebrewEvidence(version: "1.59.0", architecture: MoleAnalyzerRelease.nativeArchitecture,
            byteCount: 16, sha256: String(repeating: "a", count: 64), bottleSHA256: digest, bottleTag: "synthetic",
            sourceURL: MoleHomebrewVerifier.bottleURL(digest), checkedAt: Date()))
        continuation = nil
    }
    func fail() { continuation?.resume(throwing: MoleHomebrewVerificationFailure.installedBytesMismatch); continuation = nil }
}
private actor OnlineAnalysisFixture: MoleAnalysisExecuting {
    var runCount = 0
    func prepare(executable: URL, directory: URL) async throws -> MoleAnalysisPlan {
        throw MoleAnalysisFailure.unsupportedBinary
    }
    func prepare(executable: URL, directory: URL, verifiedArtifact: MoleAnalyzerRelease?) async throws -> MoleAnalysisPlan {
        let release = try #require(verifiedArtifact)
        return MoleAnalysisPlan(id: UUID(), executable: executable, directory: directory,
            executableIdentity: .init(device: 1, inode: 2), directoryIdentity: .init(device: 1, inode: 4),
            release: release, preparedAt: Date(), privateSessionParent: URL(fileURLWithPath: "/Synthetic/private"))
    }
    func run(_ plan: MoleAnalysisPlan) async throws -> MoleAnalysisResult {
        runCount += 1
        throw MoleAnalysisFailure.cancelled
    }
}
