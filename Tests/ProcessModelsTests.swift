import Foundation
import Testing
@testable import MoeKit

// Value-only fixtures: never enumerate, launch, inspect, signal, or terminate
// real processes, and never read actual project directories.
@Suite("Read-only process identities and paths")
struct ProcessIdentityTests {
    @Test("Complete identities preserve full kernel timestamps")
    func completeIdentity() throws {
        let identity = ProcessModelFixture.identity()
        #expect(identity.isComplete)
        #expect(identity.pid == 42)
        #expect(identity.startSeconds == ProcessModelFixture.startSeconds)
        #expect(identity.startMicroseconds == 123_456)
        #expect(identity.uid == 501)
        #expect(identity.executablePath == "/usr/local/bin/fixture-worker")
        let date = try #require(identity.startedAt)
        #expect(abs(date.timeIntervalSince1970 - (Double(ProcessModelFixture.startSeconds) + 0.123_456)) < 0.000_001)
    }

    @Test("Every identity component participates in equality and hashing")
    func identityComponents() {
        let original = ProcessModelFixture.identity()
        let variants = [
            ProcessModelFixture.identity(pid: 43),
            ProcessModelFixture.identity(seconds: ProcessModelFixture.startSeconds + 1),
            ProcessModelFixture.identity(microseconds: 123_457),
            ProcessModelFixture.identity(uid: 502),
            ProcessModelFixture.identity(path: "/usr/local/bin/replacement")
        ]
        for variant in variants {
            #expect(variant != original)
            #expect(Set([original, variant]).count == 2)
        }
    }

    @Test("Reserved and invalid PIDs are incomplete", arguments: [Int32(-1), 0, 1])
    func invalidPID(pid: Int32) {
        #expect(!ProcessModelFixture.identity(pid: pid).isComplete)
    }

    @Test("Unavailable identity fields cannot be fabricated")
    func incompleteIdentity() {
        let identities = [
            ProcessModelFixture.identity(seconds: nil),
            ProcessModelFixture.identity(seconds: 0),
            ProcessModelFixture.identity(microseconds: nil),
            ProcessModelFixture.identity(microseconds: 1_000_000),
            ProcessModelFixture.identity(uid: nil),
            ProcessModelFixture.identity(path: nil),
            ProcessModelFixture.identity(path: ""),
            ProcessModelFixture.identity(path: "relative"),
            ProcessModelFixture.identity(path: "/usr/../bin/worker")
        ]
        #expect(identities.allSatisfy { !$0.isComplete })
    }

    @Test("Unknown or invalid start timestamps remain unknown")
    func startDates() {
        #expect(ProcessModelFixture.identity(seconds: nil).startedAt == nil)
        #expect(ProcessModelFixture.identity(seconds: 0).startedAt == nil)
        #expect(ProcessModelFixture.identity(microseconds: nil).startedAt == nil)
        #expect(ProcessModelFixture.identity(microseconds: 1_000_000).startedAt == nil)
        #expect(ProcessModelFixture.identity(microseconds: 0).startedAt != nil)
        #expect(ProcessModelFixture.identity(microseconds: 999_999).startedAt != nil)
    }

    @Test("Canonical paths allow spaces, Unicode, and ordinary dot-prefixed names", arguments: [
        "/", "/work/app", "/work/my app", "/work/工作目录", "/work/.hidden", "/work/..literal"
    ])
    func canonicalPaths(path: String) {
        #expect(ProcessPath.isCanonicalAbsolute(path))
    }

    @Test("Ambiguous paths cannot supply canonical evidence", arguments: [
        "", "work/app", "./work/app", "/work/app/", "/work//app", "//work/app",
        "/work/./app", "/work/../app", "/work/app\0other"
    ])
    func noncanonicalPaths(path: String) {
        #expect(!ProcessPath.isCanonicalAbsolute(path))
        #expect(!ProcessPath.contains(path, in: "/work"))
        #expect(!ProcessPath.contains("/work/app", in: path))
    }

    @Test("Containment respects component boundaries and excludes the filesystem root")
    func pathBoundaries() {
        #expect(ProcessPath.contains("/work/app", in: "/work/app"))
        #expect(ProcessPath.contains("/work/app/src", in: "/work/app"))
        for path in ["/work/application", "/work/app-other", "/work/App/src", "/work"] {
            #expect(!ProcessPath.contains(path, in: "/work/app"))
        }
        #expect(!ProcessPath.contains("/work/app", in: "/"))
        #expect(!ProcessPath.contains("/", in: "/"))
    }

    @Test("Unknown listener data differs from a confirmed empty set")
    func unknownPorts() {
        let unknown = ProcessModelFixture.record(ports: nil)
        let empty = ProcessModelFixture.record(ports: [])
        #expect(unknown.listeningPorts == nil)
        #expect(empty.listeningPorts == [])
        #expect(unknown != empty)
        #expect(unknown.id == unknown.identity)
    }

    @Test("Listener identity preserves local bind address, port, and transport")
    func listenerIdentity() {
        let first = ListeningPort(port: 3_000, address: "127.0.0.1", transport: "TCP")
        let ports: Set<ListeningPort> = [
            first, first,
            ListeningPort(port: 3_001, address: "127.0.0.1", transport: "TCP"),
            ListeningPort(port: 3_000, address: "::1", transport: "TCP"),
            ListeningPort(port: 3_000, address: "127.0.0.1", transport: "UDP")
        ]
        #expect(ports.count == 4)
    }

    @Test("Scan defaults retain finite, explicit budgets")
    func defaultBudgets() {
        let options = ProcessScanOptions()
        #expect(options.maximumProcesses == 4_096)
        #expect(options.maximumFileDescriptorsPerProcess == 256)
        #expect(options.maximumDuration == 5)
    }
}

@Suite("Conservative discovered process association")
struct ProcessAssociationTests {
    @Test("Canonical working-directory evidence is inferred, never managed")
    func inferredAssociation() {
        let project = ProcessModelFixture.project()
        let association = ProcessClassifier.association(for: ProcessModelFixture.record(), projects: [project])
        guard case let .inferred(id, name, evidence) = association else {
            Issue.record("A matching working directory must produce only an inferred association.")
            return
        }
        #expect(id == project.id)
        #expect(name == project.name)
        #expect(!evidence.isEmpty)
        #expect(association.projectID == project.id)
        #expect(association.projectName == project.name)
        #expect(association.title == String(localized: "Observed association"))
    }

    @Test("Nested roots select the deepest project regardless of catalog order")
    func nestedRoots() {
        let outer = ProcessModelFixture.project()
        let inner = ProcessModelFixture.project(path: "/work/app/nested", name: "Inner")
        let row = ProcessModelFixture.record(cwd: "/work/app/nested/src")
        for projects in [[outer, inner], [inner, outer]] {
            #expect(ProcessClassifier.association(for: row, projects: projects).projectID == inner.id)
        }
    }

    @Test("Exact roots match but prefix siblings do not")
    func projectBoundaries() {
        let project = ProcessModelFixture.project()
        #expect(ProcessClassifier.association(for: ProcessModelFixture.record(cwd: "/work/app"), projects: [project]).projectID == project.id)
        for cwd in ["/work/application", "/work/app-other", "/work/app2/src", "/work"] {
            #expect(ProcessClassifier.association(for: ProcessModelFixture.record(cwd: cwd), projects: [project]) == .unknown)
        }
    }

    @Test("Aliases of the deepest canonical root remain ambiguous")
    func ambiguousAliases() {
        let outer = ProcessModelFixture.project(path: "/work", name: "Outer")
        let first = ProcessModelFixture.project(name: "Alias one")
        let second = ProcessModelFixture.project(name: "Alias two")
        for projects in [[outer, first, second], [second, outer, first], [first, first]] {
            #expect(ProcessClassifier.association(for: ProcessModelFixture.record(), projects: projects) == .unknown)
        }
    }

    @Test("Duplicate outer roots do not hide a unique deeper project")
    func uniqueInnerRoot() {
        let first = ProcessModelFixture.project(path: "/work", name: "Outer one")
        let second = ProcessModelFixture.project(path: "/work", name: "Outer two")
        let inner = ProcessModelFixture.project()
        #expect(ProcessClassifier.association(for: ProcessModelFixture.record(), projects: [first, second, inner]).projectID == inner.id)
    }

    @Test("Unavailable or noncanonical working directories are unattributed")
    func unknownWorkingDirectory() {
        let project = ProcessModelFixture.project()
        let directories: [String?] = [nil, "", "work/app", "/work/app/", "/work/app/../other", "/work//app/src", "/elsewhere"]
        for cwd in directories {
            #expect(ProcessClassifier.association(for: ProcessModelFixture.record(cwd: cwd), projects: [project]) == .unknown)
        }
        #expect(ProcessClassifier.association(for: ProcessModelFixture.record(), projects: []) == .unknown)
    }

    @Test("Unresolved aliases are not guessed; canonicalization belongs to the provider")
    func physicalAliases() {
        let project = ProcessModelFixture.project(path: "/private/var/tmp/app")
        #expect(ProcessClassifier.association(for: ProcessModelFixture.record(cwd: "/var/tmp/app/src"), projects: [project]) == .unknown)
        #expect(ProcessClassifier.association(for: ProcessModelFixture.record(cwd: "/private/var/tmp/app/src"), projects: [project]).projectID == project.id)
    }

    @Test("Root and malformed catalog scopes cannot associate every process", arguments: [
        "/", "work/app", "/work/app/", "/work/../app", "/work//app"
    ])
    func malformedProjectRoot(path: String) {
        #expect(ProcessClassifier.association(for: ProcessModelFixture.record(), projects: [ProcessModelFixture.project(path: path)]) == .unknown)
    }

    @Test("Executable location, name, parent, group, and ports do not establish ownership")
    func metadataIsNotOwnership() {
        let row = ProcessModelFixture.record(
            identity: ProcessModelFixture.identity(path: "/work/app/bin/worker"),
            name: "app", parent: 40, group: 40, cwd: nil,
            ports: [ListeningPort(port: 3_000, address: "127.0.0.1", transport: "TCP")]
        )
        #expect(ProcessClassifier.association(for: row, projects: [ProcessModelFixture.project()]) == .unknown)
    }

    @Test("The reserved managed case does not invent a project association")
    func managedRequiresLedger() {
        let managed = ProcessAssociation.managed(sessionID: UUID())
        #expect(managed.projectID == nil)
        #expect(managed.projectName == nil)
        #expect(managed.evidence == String(localized: "A matching MoeKit launch record is required."))
        #expect(ProcessAssociation.unknown.projectID == nil)
        #expect(ProcessAssociation.unknown.projectName == nil)
        #expect(!ProcessAssociation.unknown.evidence.isEmpty)
    }
}

@Suite("Process inventory explanations and port filters")
struct ProcessInventoryExplanationTests {
    @Test("Attribution explains missing cwd without inferring from ports")
    func missingDirectoryEvidence() {
        let record = ProcessModelFixture.record(cwd: nil,
            ports: [ListeningPort(port: 3_000, address: "127.0.0.1", transport: "TCP")])
        let result = ProcessClassifier.assessment(for: record, projects: [ProcessModelFixture.project()])
        #expect(result.association == .unknown)
        #expect(result.canonicalProjectPath == nil)
        #expect(result.explanation == String(localized: "Working directory is unavailable or unresolved. Names, ports and parent processes do not establish a project association."))
    }

    @Test("Empty, unmatched and ambiguous project scopes have distinct explanations")
    func distinctUnknownReasons() {
        let row = ProcessModelFixture.record()
        let empty = ProcessClassifier.assessment(for: row, projects: [])
        let invalid = ProcessClassifier.assessment(for: row, projects: [ProcessModelFixture.project(path: "/")])
        let unmatched = ProcessClassifier.assessment(for: row, projects: [ProcessModelFixture.project(path: "/other")])
        let duplicate = ProcessClassifier.assessment(for: row, projects: [ProcessModelFixture.project(), ProcessModelFixture.project()])
        #expect(empty.explanation == invalid.explanation)
        #expect(Set([empty.explanation, unmatched.explanation, duplicate.explanation]).count == 3)
        for result in [empty, invalid, unmatched, duplicate] {
            #expect(result.association == .unknown)
            #expect(result.canonicalProjectPath == nil)
        }
    }

    @Test("Matched evidence carries only the deepest unique canonical root")
    func matchedRootEvidence() {
        let outer = ProcessModelFixture.project(path: "/work", name: "Outer")
        let project = ProcessModelFixture.project()
        let row = ProcessModelFixture.record()
        let result = ProcessClassifier.assessment(for: row, projects: [outer, project])
        #expect(result.association.projectID == project.id)
        #expect(result.canonicalProjectPath == project.canonicalPath)
        #expect(result.explanation == result.association.evidence)
        let target = ProcessModelFixture.plan([row]).targets.first
        #expect(target?.associationEvidence == result.explanation)
        #expect(target?.canonicalProjectPath == result.canonicalProjectPath)
    }

    @Test("Listener filters preserve unknown versus observed-empty coverage")
    func portCoverageFilters() {
        let unknown = ProcessModelFixture.record(ports: nil)
        let empty = ProcessModelFixture.record(ports: [])
        let listener = ProcessModelFixture.record(ports: [ListeningPort(port: 3_000, address: "::1", transport: "TCP")])
        for row in [unknown, empty, listener] { #expect(ProcessPortFilter.all.includes(row)) }
        #expect(ProcessPortFilter.unknown.includes(unknown))
        #expect(!ProcessPortFilter.unknown.includes(empty))
        #expect(!ProcessPortFilter.unknown.includes(listener))
        #expect(ProcessPortFilter.listening.includes(listener))
        #expect(!ProcessPortFilter.listening.includes(empty))
        #expect(!ProcessPortFilter.listening.includes(unknown))
    }

    @Test("Protection totals do not confuse generic review risks with protection flags")
    func protectionSummary() {
        let worker = ProcessModelFixture.record()
        let database = ProcessModelFixture.record(identity: ProcessModelFixture.identity(pid: 43, path: "/usr/local/bin/postgres"), name: "postgres")
        let plan = ProcessModelFixture.plan([worker, database])
        #expect(plan.targets.count == 2)
        #expect(plan.targets.allSatisfy { !$0.risks.isEmpty })
        #expect(plan.protectedTargetCount == 1)
        #expect(!plan.canExecute)
    }
}

@Suite("Protected process review")
struct ProcessProtectionTests {
    @Test("Browser, IDE, database, VM, and shared-service names remain guarded", arguments: [
        "Google Chrome", "chromium", "Safari", "firefox", "webkit", "brave", "msedge", "browser-helper",
        "Xcode", "Code Helper", "electron", "idea", "pycharm", "webstorm", "Cursor", "zed",
        "docker", "containerd", "podman", "qemu-system-aarch64", "VirtualBox", "vmware-vmx", "parallels", "colima",
        "postgres", "mysqld", "mariadbd", "mongod", "redis-server", "sqlite3", "ollama"
    ])
    func guardedNames(name: String) {
        let row = ProcessModelFixture.record(name: name)
        #expect(!ProcessClassifier.protectionReasons(for: row, snapshot: ProcessModelFixture.snapshot([row])).isEmpty)
    }

    @Test("Executable hints protect a process despite an innocuous displayed name", arguments: [
        "/opt/homebrew/bin/postgres", "/usr/local/bin/qemu-system-x86_64",
        "/Applications/Fixture.app/Contents/MacOS/worker", "/usr/local/bin/CHROME"
    ])
    func guardedExecutables(path: String) {
        let row = ProcessModelFixture.record(identity: ProcessModelFixture.identity(path: path), name: "worker")
        #expect(!ProcessClassifier.protectionReasons(for: row, snapshot: ProcessModelFixture.snapshot([row])).isEmpty)
    }

    @Test("System services and shared shells remain protected", arguments: [
        "launchd", "sshd", "WindowServer", "loginwindow", "kernel_task", "bash", "zsh", "sh", "fish", "tmux", "screen"
    ])
    func systemProcesses(binary: String) {
        let row = ProcessModelFixture.record(identity: ProcessModelFixture.identity(path: "/usr/bin/\(binary)"), name: binary)
        #expect(!ProcessClassifier.protectionReasons(for: row, snapshot: ProcessModelFixture.snapshot([row])).isEmpty)
    }

    @Test("Self, system PIDs, other owners, and incomplete identities are protected")
    func protectedIdentities() {
        let identities = [
            ProcessModelFixture.identity(pid: ProcessModelFixture.observerPID),
            ProcessModelFixture.identity(pid: 1), ProcessModelFixture.identity(pid: 0),
            ProcessModelFixture.identity(uid: 0), ProcessModelFixture.identity(uid: 502),
            ProcessModelFixture.identity(uid: nil), ProcessModelFixture.identity(path: nil),
            ProcessModelFixture.identity(seconds: nil)
        ]
        for identity in identities {
            let row = ProcessModelFixture.record(identity: identity)
            #expect(!ProcessClassifier.protectionReasons(for: row, snapshot: ProcessModelFixture.snapshot([row])).isEmpty)
        }
    }

    @Test("Missing names cannot be presented as unprotected", arguments: ["", " ", "\n\t"])
    func missingName(name: String) {
        let row = ProcessModelFixture.record(name: name)
        #expect(!ProcessClassifier.protectionReasons(for: row, snapshot: ProcessModelFixture.snapshot([row])).isEmpty)
    }

    @Test("Future process start times remain a protection concern")
    func impossibleStartTime() {
        let row = ProcessModelFixture.record(identity: ProcessModelFixture.identity(seconds: 1_800_000_001))
        #expect(ProcessClassifier.protectionReasons(for: row, snapshot: ProcessModelFixture.snapshot([row])).contains(
            String(localized: "Process start time is inconsistent with this snapshot.")
        ))
    }

    @Test("Inferred project association cannot waive browser protections or enable execution")
    func associatedBrowser() throws {
        let row = ProcessModelFixture.record(name: "Chrome")
        let plan = ProcessModelFixture.plan([row])
        let target = try #require(plan.targets.first)
        #expect(target.association.projectID == ProcessModelFixture.projectID)
        #expect(!target.risks.isEmpty)
        #expect(!plan.canExecute)
        if case .managed = target.association { Issue.record("Discovery must never claim launch ownership.") }
    }
}

@Suite("Inspection-only stop plans")
struct ProcessStopPlanTests {
    @Test("A complete fresh plan preserves evidence but never enables execution")
    func previewOnly() throws {
        let row = ProcessModelFixture.record()
        let snapshot = ProcessModelFixture.snapshot([row])
        let plan = ProcessStopPlanner.makePlan(snapshot: snapshot, selection: [row.identity], projects: [ProcessModelFixture.project()], now: ProcessModelFixture.now)
        let target = try #require(plan.targets.first)
        #expect(!plan.canExecute)
        #expect(plan.snapshotID == snapshot.id)
        #expect(plan.snapshotDate == snapshot.capturedAt)
        #expect(plan.createdAt == ProcessModelFixture.now)
        #expect(plan.currentUID == snapshot.currentUID)
        #expect(plan.observerPID == snapshot.observerPID)
        #expect(plan.selectedIdentities == [row.identity])
        #expect(target.id == row.identity)
        #expect(target.record == row)
        #expect(target.name == row.name)
        #expect(plan.warnings.contains(String(localized: "Review is not permission to stop. A fresh identity check and explicit confirmation are required.")))
        #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: snapshot, selection: [row.identity], now: ProcessModelFixture.now).isEmpty)
        #expect(!plan.canExecute)
    }

    @Test("Only exact selections appear in PID order; parents, children, and siblings never expand")
    func exactSelectionOnly() {
        let parent = ProcessModelFixture.record(identity: ProcessModelFixture.identity(pid: 30), group: 30)
        let selected = ProcessModelFixture.record(parent: 30, group: 30)
        let child = ProcessModelFixture.record(identity: ProcessModelFixture.identity(pid: 43), parent: 42, group: 30)
        let sibling = ProcessModelFixture.record(identity: ProcessModelFixture.identity(pid: 44), parent: 30, group: 30)
        let other = ProcessModelFixture.record(identity: ProcessModelFixture.identity(pid: 90), group: 90)
        let plan = ProcessModelFixture.plan([other, sibling, child, selected, parent], selection: [other.identity, selected.identity])
        #expect(plan.targets.map(\.identity) == [selected.identity, other.identity])
        #expect(plan.selectedIdentities == [selected.identity, other.identity])
        #expect(plan.targets.first?.risks.contains(String(localized: "The observed process group includes unselected processes. No group action is planned.")) == true)
        #expect(!plan.canExecute)
    }

    @Test("A shared browser process group never broadens a selected target")
    func sharedGroup() throws {
        let row = ProcessModelFixture.record(group: 700)
        let browser = ProcessModelFixture.record(identity: ProcessModelFixture.identity(pid: 99), name: "Chrome", group: 700, cwd: "/elsewhere")
        let plan = ProcessModelFixture.plan([row, browser], selection: [row.identity])
        let target = try #require(plan.targets.first)
        #expect(plan.targets.count == 1)
        #expect(target.identity == row.identity)
        #expect(target.risks.contains(String(localized: "The observed process group includes unselected processes. No group action is planned.")))
        #expect(!plan.canExecute)
    }

    @Test("An absent or reparented parent is never proof of abandonment", arguments: [Int32(1), 65_000])
    func absentParent(parent: Int32) throws {
        let row = ProcessModelFixture.record(parent: parent)
        let plan = ProcessModelFixture.plan([row])
        let target = try #require(plan.targets.first)
        #expect(target.risks.contains(String(localized: "Parent is unavailable or reparented. This does not mean the process is abandoned.")))
        #expect(plan.targets.map(\.identity) == [row.identity])
        #expect(target.association.projectID == ProcessModelFixture.projectID)
        #expect(!plan.canExecute)
    }

    @Test("An unreadable parent does not invent ownership or permission")
    func unknownParent() throws {
        let row = ProcessModelFixture.record(parent: nil, cwd: nil)
        let plan = ProcessModelFixture.plan([row])
        let target = try #require(plan.targets.first)
        #expect(target.association == .unknown)
        #expect(target.risks.contains(String(localized: "No project ownership was established.")))
        #expect(!plan.canExecute)
    }

    @Test("Missing metadata and partial reads remain visible")
    func missingMetadata() throws {
        for row in [
            ProcessModelFixture.record(cwd: nil),
            ProcessModelFixture.record(ports: nil),
            ProcessModelFixture.record(issues: ["Synthetic descriptor limit reached."])
        ] {
            let plan = ProcessModelFixture.plan([row])
            let target = try #require(plan.targets.first)
            #expect(target.risks.contains(String(localized: "Some metadata is unavailable or incomplete.")))
            #expect(!plan.canExecute)
        }
    }

    @Test("Unrelated working directories remain unattributed")
    func unattributedTarget() throws {
        let plan = ProcessModelFixture.plan([ProcessModelFixture.record(cwd: "/elsewhere")])
        let target = try #require(plan.targets.first)
        #expect(target.association == .unknown)
        #expect(target.risks.contains(String(localized: "No project ownership was established.")))
    }

    @Test("Empty and unavailable selections never fabricate targets")
    func emptyAndMissingSelection() {
        let row = ProcessModelFixture.record()
        let missing = ProcessModelFixture.identity(pid: 404)
        let empty = ProcessModelFixture.plan([row], selection: [])
        let absent = ProcessModelFixture.plan([row], selection: [missing])
        #expect(empty.targets.isEmpty)
        #expect(empty.selectedIdentities.isEmpty)
        #expect(absent.targets.isEmpty)
        #expect(absent.selectedIdentities == [missing])
        #expect(absent.warnings.contains(String(localized: "Some selected identities are no longer in this snapshot.")))
        #expect(!empty.canExecute)
        #expect(!absent.canExecute)
    }

    @Test("Reusing a PID cannot satisfy a selection for an older identity")
    func reusedPIDSelection() {
        let selected = ProcessModelFixture.identity()
        let reused = ProcessModelFixture.record(identity: ProcessModelFixture.identity(microseconds: 123_457))
        let plan = ProcessModelFixture.plan([reused], selection: [selected])
        #expect(plan.targets.isEmpty)
        #expect(plan.selectedIdentities == [selected])
        #expect(!plan.canExecute)
    }

    @Test("Partial, stale, and future snapshots receive warnings")
    func snapshotWarnings() {
        let row = ProcessModelFixture.record()
        var partial = ProcessModelFixture.snapshot([row])
        partial.isPartial = true
        let partialPlan = ProcessStopPlanner.makePlan(snapshot: partial, selection: [row.identity], projects: [], now: ProcessModelFixture.now)
        #expect(partialPlan.warnings.contains(String(localized: "This is a partial snapshot; unseen processes or dependencies may exist.")))
        for offset in [-16.0, 0.001] {
            let snapshot = ProcessModelFixture.snapshot([row], capturedAt: ProcessModelFixture.now.addingTimeInterval(offset))
            let plan = ProcessStopPlanner.makePlan(snapshot: snapshot, selection: [row.identity], projects: [], now: ProcessModelFixture.now)
            #expect(plan.warnings.contains(String(localized: "This snapshot is stale or has an invalid timestamp. Refresh before reviewing a future action.")))
            #expect(!plan.canExecute)
        }
    }
}

@Suite("Stop-plan revalidation fails closed")
struct ProcessStopPlanInvalidationTests {
    @Test("A matching fresh snapshot can confirm evidence without enabling execution")
    func freshUnchangedSnapshot() {
        let row = ProcessModelFixture.record()
        let original = ProcessModelFixture.snapshot([row], capturedAt: ProcessModelFixture.now.addingTimeInterval(-1))
        let plan = ProcessStopPlanner.makePlan(snapshot: original, selection: [row.identity], projects: [], now: ProcessModelFixture.now)
        let fresh = ProcessModelFixture.snapshot([row])
        #expect(original.id != fresh.id)
        #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: fresh, selection: [row.identity], now: ProcessModelFixture.now).isEmpty)
        #expect(!plan.canExecute)
    }

    @Test("Clearing, replacing, or broadening selections invalidates a prior review")
    func selectionChanges() {
        let row = ProcessModelFixture.record()
        let other = ProcessModelFixture.record(identity: ProcessModelFixture.identity(pid: 43))
        let snapshot = ProcessModelFixture.snapshot([row, other])
        let plan = ProcessModelFixture.plan([row, other], selection: [row.identity])
        let cleared = ProcessStopPlanner.invalidations(for: plan, snapshot: snapshot, selection: [], now: ProcessModelFixture.now)
        #expect(cleared.contains(.emptySelection))
        #expect(cleared.contains(.selectionChanged))
        let alternatives: [Set<ProcessIdentity>] = [[other.identity], [row.identity, other.identity]]
        for selection in alternatives {
            #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: snapshot, selection: selection, now: ProcessModelFixture.now).contains(.selectionChanged))
        }
    }

    @Test("An initially empty plan remains invalid")
    func emptyPlan() {
        let plan = ProcessModelFixture.plan([], selection: [])
        #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: ProcessModelFixture.snapshot([]), selection: [], now: ProcessModelFixture.now).contains(.emptySelection))
        #expect(!plan.canExecute)
    }

    @Test("Snapshot age has a precise 15-second boundary and rejects future captures")
    func ageBoundaries() {
        let row = ProcessModelFixture.record()
        let plan = ProcessModelFixture.plan([row])
        #expect(ProcessStopPlanner.maximumSnapshotAge == 15)
        for age in [0.0, 14.999, 15.0] {
            let snapshot = ProcessModelFixture.snapshot([row], capturedAt: ProcessModelFixture.now.addingTimeInterval(-age))
            let result = ProcessStopPlanner.invalidations(for: plan, snapshot: snapshot, selection: [row.identity], now: ProcessModelFixture.now)
            #expect(!result.contains(.staleSnapshot))
            #expect(!result.contains(.snapshotFromFuture))
        }
        let stale = ProcessModelFixture.snapshot([row], capturedAt: ProcessModelFixture.now.addingTimeInterval(-15.001))
        #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: stale, selection: [row.identity], now: ProcessModelFixture.now).contains(.staleSnapshot))
        let future = ProcessModelFixture.snapshot([row], capturedAt: ProcessModelFixture.now.addingTimeInterval(0.001))
        #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: future, selection: [row.identity], now: ProcessModelFixture.now).contains(.snapshotFromFuture))
    }

    @Test("Future process starts invalidate even when their identity is otherwise complete")
    func impossibleStartTime() {
        let row = ProcessModelFixture.record(identity: ProcessModelFixture.identity(seconds: 1_800_000_001))
        let plan = ProcessModelFixture.plan([row])
        let result = ProcessStopPlanner.invalidations(for: plan, snapshot: ProcessModelFixture.snapshot([row]), selection: [row.identity], now: ProcessModelFixture.now)
        #expect(result.contains(.invalidStartTime(row.identity)))
        #expect(!plan.canExecute)
    }

    @Test("Changing the observing UID or observer process invalidates old safety context")
    func safetyContextChanges() {
        let row = ProcessModelFixture.record()
        let plan = ProcessModelFixture.plan([row])
        for snapshot in [
            ProcessModelFixture.snapshot([row], uid: 502),
            ProcessModelFixture.snapshot([row], observer: row.identity.pid)
        ] {
            #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: snapshot, selection: [row.identity], now: ProcessModelFixture.now).contains(.safetyContextChanged))
        }
    }

    @Test("Each identity component detects reuse or replacement of the same PID")
    func identityReplacement() {
        let original = ProcessModelFixture.record()
        let plan = ProcessModelFixture.plan([original])
        let replacements = [
            ProcessModelFixture.identity(seconds: ProcessModelFixture.startSeconds + 1),
            ProcessModelFixture.identity(microseconds: 123_457),
            ProcessModelFixture.identity(uid: 502),
            ProcessModelFixture.identity(path: "/usr/local/bin/replacement"),
            ProcessModelFixture.identity(seconds: nil),
            ProcessModelFixture.identity(uid: nil),
            ProcessModelFixture.identity(path: nil)
        ]
        for identity in replacements {
            let snapshot = ProcessModelFixture.snapshot([ProcessModelFixture.record(identity: identity)])
            #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: snapshot, selection: [original.identity], now: ProcessModelFixture.now).contains(.identityChanged(original.identity.pid)))
        }
    }

    @Test("A missing target differs from another incarnation of the same PID")
    func disappearedTarget() {
        let row = ProcessModelFixture.record()
        let plan = ProcessModelFixture.plan([row])
        let unrelated = ProcessModelFixture.record(identity: ProcessModelFixture.identity(pid: 43))
        let result = ProcessStopPlanner.invalidations(for: plan, snapshot: ProcessModelFixture.snapshot([unrelated]), selection: [row.identity], now: ProcessModelFixture.now)
        #expect(result.contains(.missingTarget(row.identity)))
        #expect(!result.contains(.identityChanged(row.identity.pid)))
    }

    @Test("A target absent from the original preview cannot be retroactively approved")
    func neverReviewedTarget() {
        let row = ProcessModelFixture.record()
        let plan = ProcessModelFixture.plan([], selection: [row.identity])
        #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: ProcessModelFixture.snapshot([row]), selection: [row.identity], now: ProcessModelFixture.now).contains(.missingTarget(row.identity)))
    }

    @Test("Unchanged incomplete identities still invalidate a plan")
    func incompleteIdentities() {
        for identity in [
            ProcessModelFixture.identity(seconds: nil),
            ProcessModelFixture.identity(microseconds: nil),
            ProcessModelFixture.identity(microseconds: 1_000_000),
            ProcessModelFixture.identity(uid: nil),
            ProcessModelFixture.identity(path: nil)
        ] {
            let row = ProcessModelFixture.record(identity: identity)
            let plan = ProcessModelFixture.plan([row])
            #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: ProcessModelFixture.snapshot([row]), selection: [identity], now: ProcessModelFixture.now).contains(.incompleteIdentity(identity)))
            #expect(!plan.canExecute)
        }
    }

    @Test("Name, parent, group, working directory, and metadata issues are reviewed evidence")
    func metadataChanges() {
        let original = ProcessModelFixture.record()
        let plan = ProcessModelFixture.plan([original])
        let replacements = [
            ProcessModelFixture.record(name: "different worker"),
            ProcessModelFixture.record(parent: 1), ProcessModelFixture.record(parent: nil),
            ProcessModelFixture.record(group: 900), ProcessModelFixture.record(group: nil),
            ProcessModelFixture.record(cwd: "/work/other"), ProcessModelFixture.record(cwd: nil),
            ProcessModelFixture.record(issues: ["Synthetic metadata read failed."])
        ]
        for row in replacements {
            #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: ProcessModelFixture.snapshot([row]), selection: [original.identity], now: ProcessModelFixture.now).contains(.metadataChanged(original.identity)))
        }
    }

    @Test("Listener addition, removal, address, transport, and coverage changes invalidate review")
    func listenerChanges() {
        let port = ListeningPort(port: 3_000, address: "127.0.0.1", transport: "TCP")
        let original = ProcessModelFixture.record(ports: [port])
        let plan = ProcessModelFixture.plan([original])
        let replacements: [[ListeningPort]?] = [
            nil, [],
            [ListeningPort(port: 3_001, address: "127.0.0.1", transport: "TCP")],
            [ListeningPort(port: 3_000, address: "::", transport: "TCP")],
            [ListeningPort(port: 3_000, address: "127.0.0.1", transport: "UDP")],
            [port, ListeningPort(port: 3_001, address: "127.0.0.1", transport: "TCP")]
        ]
        for ports in replacements {
            let row = ProcessModelFixture.record(ports: ports)
            #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: ProcessModelFixture.snapshot([row]), selection: [original.identity], now: ProcessModelFixture.now).contains(.metadataChanged(original.identity)))
        }
    }

    @Test("Unknown listeners becoming confirmed empty still require a new review")
    func unknownPortsBecomeKnown() {
        let original = ProcessModelFixture.record(ports: nil)
        let plan = ProcessModelFixture.plan([original])
        let fresh = ProcessModelFixture.record(ports: [])
        #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: ProcessModelFixture.snapshot([fresh]), selection: [original.identity], now: ProcessModelFixture.now).contains(.metadataChanged(original.identity)))
    }

    @Test("Partial snapshots invalidate unchanged selected records")
    func partialSnapshot() {
        let row = ProcessModelFixture.record()
        let plan = ProcessModelFixture.plan([row])
        var snapshot = ProcessModelFixture.snapshot([row])
        snapshot.isPartial = true
        snapshot.issues = ["Synthetic process budget exhausted."]
        #expect(ProcessStopPlanner.invalidations(for: plan, snapshot: snapshot, selection: [row.identity], now: ProcessModelFixture.now).contains(.partialSnapshot))
        #expect(!plan.canExecute)
    }

    @Test("Independent invalidation reasons accumulate")
    func multipleInvalidations() {
        let row = ProcessModelFixture.record()
        let plan = ProcessModelFixture.plan([row])
        var snapshot = ProcessModelFixture.snapshot([], capturedAt: ProcessModelFixture.now.addingTimeInterval(-20))
        snapshot.isPartial = true
        let result = ProcessStopPlanner.invalidations(for: plan, snapshot: snapshot, selection: [], now: ProcessModelFixture.now)
        #expect(result.contains(.emptySelection))
        #expect(result.contains(.selectionChanged))
        #expect(result.contains(.staleSnapshot))
        #expect(result.contains(.partialSnapshot))
        #expect(result.contains(.missingTarget(row.identity)))
    }
}

private enum ProcessModelFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let startSeconds: UInt64 = 1_799_999_900
    static let observerPID: Int32 = 9_999
    static let projectID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    static func identity(
        pid: Int32 = 42,
        seconds: UInt64? = ProcessModelFixture.startSeconds,
        microseconds: UInt64? = 123_456,
        uid: UInt32? = 501,
        path: String? = "/usr/local/bin/fixture-worker"
    ) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startSeconds: seconds, startMicroseconds: microseconds, uid: uid, executablePath: path)
    }

    static func record(
        identity: ProcessIdentity = ProcessModelFixture.identity(),
        name: String = "fixture-worker",
        parent: Int32? = 40,
        group: Int32? = 42,
        cwd: String? = "/work/app/src",
        ports: [ListeningPort]? = [],
        issues: [String] = []
    ) -> ProcessInventoryRecord {
        ProcessInventoryRecord(identity: identity, name: name, parentPID: parent, processGroupID: group,
                               workingDirectory: cwd, listeningPorts: ports, metadataIssues: issues)
    }

    static func snapshot(
        _ records: [ProcessInventoryRecord],
        capturedAt: Date = ProcessModelFixture.now,
        uid: UInt32 = 501,
        observer: Int32 = ProcessModelFixture.observerPID
    ) -> ProcessSnapshot {
        ProcessSnapshot(capturedAt: capturedAt, records: records, currentUID: uid, observerPID: observer)
    }

    static func project(path: String = "/work/app", name: String = "Fixture project") -> ProcessProjectScope {
        let id = path == "/work/app" && name == "Fixture project" ? projectID : UUID()
        return ProcessProjectScope(id: id, name: name, canonicalPath: path)
    }

    static func plan(_ records: [ProcessInventoryRecord], selection: Set<ProcessIdentity>? = nil) -> StopPlan {
        ProcessStopPlanner.makePlan(snapshot: snapshot(records), selection: selection ?? Set(records.map(\.identity)),
                                    projects: [project()], now: now)
    }
}
