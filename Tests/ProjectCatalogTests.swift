import Foundation
import Testing
@testable import MoeKit

struct ProjectCatalogTests {
    private func metadata(_ directory: String, common: String? = nil, linked: Bool = false, locked: Bool = false) -> GitDiscoveryMetadata {
        GitDiscoveryMetadata(observedAt: Date(timeIntervalSince1970: 100), gitDirectoryPath: directory,
            commonDirectoryPath: common ?? directory, isLinkedWorktree: linked, isLocked: locked)
    }

    @Test("Repeated import refreshes evidence without duplicating or losing user metadata")
    func refreshKeepsIdentity() throws {
        let old = ProjectRecord(name: "My custom name", path: "/fixture/project", kind: .repository,
            branch: "old", lastOpened: Date(timeIntervalSince1970: 50), isPinned: true)
        let item = DiscoveredRepository(url: old.url, name: "project", kind: .gitRepository,
            branch: "new", metadata: metadata("/fixture/project/.git"))
        let once = ProjectCatalog.merging([item, item], into: [old])
        let twice = ProjectCatalog.merging([item], into: once)
        #expect(twice.count == 1)
        let refreshed = try #require(twice.first)
        #expect(refreshed.id == old.id)
        #expect(refreshed.name == old.name)
        #expect(refreshed.isPinned)
        #expect(refreshed.lastOpened == old.lastOpened)
        #expect(refreshed.branch == "new")
        #expect(refreshed.status == String(localized: "Not checked"))
    }

    @Test("Only validated worktrees group under their imported main repository")
    func relationshipGrouping() throws {
        let main = DiscoveredRepository(url: URL(fileURLWithPath: "/fixture/main"), name: "main", kind: .gitRepository,
            branch: "main", metadata: metadata("/fixture/main/.git"))
        let work = DiscoveredRepository(url: URL(fileURLWithPath: "/fixture/work"), name: "work", kind: .gitWorktree,
            branch: "topic", metadata: metadata("/fixture/main/.git/worktrees/work", common: "/fixture/main/.git", linked: true))
        let records = ProjectCatalog.merging([work, main], into: [])
        let mainRecord = try #require(records.first { $0.path == main.url.path })
        let workRecord = try #require(records.first { $0.path == work.url.path })
        #expect(workRecord.kind == .worktree)
        #expect(workRecord.parentID == mainRecord.id)
        #expect(mainRecord.parentID == nil)
        #expect(ProjectCatalog.merging([work], into: []).first?.parentID == nil)
    }

    @Test("An incomplete refresh clears stale branch and relationship evidence")
    func unknownRefreshClearsEvidence() throws {
        let old = ProjectRecord(name: "work", path: "/fixture/work", kind: .worktree, branch: "old", parentID: UUID(),
            gitMetadata: metadata("/fixture/main/.git/worktrees/work", common: "/fixture/main/.git", linked: true))
        let item = DiscoveredRepository(url: old.url, name: old.name, kind: .gitWorktree, branch: nil)
        let record = try #require(ProjectCatalog.merging([item], into: [old]).first)
        #expect(record.branch == nil)
        #expect(record.gitMetadata == nil)
        #expect(record.parentID == nil)
        #expect(record.kind == .linkedGitDirectory)
        #expect(record.id == old.id)
    }

    @Test("Unknown, locked and apparently normal worktrees remain protected")
    func noCleanupEligibilityFromMetadata() {
        for locked in [true, false] {
            let project = ProjectRecord(name: "work", path: "/fixture/work", kind: .worktree,
                gitMetadata: metadata("/fixture/main/.git/worktrees/work", common: "/fixture/main/.git", linked: true, locked: locked))
            let preview = ProjectCleanupPreview(project: project)
            #expect(!preview.isEligible)
            #expect(preview.path == project.path)
            #expect(preview.reasons.count >= 4)
        }
        let unknown = ProjectRecord(name: "unknown", path: "/fixture/unknown", kind: .repository)
        #expect(!ProjectCleanupPreview(project: unknown).isEligible)
        #expect(ProjectCleanupPreview(project: unknown).reasons.count == 6)
    }

    @Test("Pre-metadata catalogs decode with an unknown snapshot")
    func legacyCatalogDecode() throws {
        let project = ProjectRecord(name: "legacy", path: "/fixture/legacy", kind: .repository)
        let encoded = try JSONEncoder().encode(project)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "gitMetadata")
        let decoded = try JSONDecoder().decode(ProjectRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.id == project.id)
        #expect(decoded.gitMetadata == nil)
    }
}
