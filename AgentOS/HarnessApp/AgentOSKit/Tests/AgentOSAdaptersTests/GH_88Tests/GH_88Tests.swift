// API contract: Workspace.prepareRequirementBranch(for:leaves:) binds leaves to a top-level
// NodeIdentity, creates agentos/<ticketKey> from current main once, and returns its creation
// commit (nil if already present). Reconciler records
// EventKind.requirementBranchCreated(branch:from:) on the requirement in the ledger.
// Workspace.createSnapshot(for:) reads that leaf's requirement, not a global landing branch.
// Workspace.catchUpRequirements(in:busy:) catches up requirement branches and their idle active
// leaves through Workspace.catchUpRequirementBranch(for:). RepositorySnapshot exposes the
// number of local agentos/main commits absent from main as legacyLandingCommitsAhead.
// Recording-workspace tests observe reconciler routing; temporary local repositories verify
// RepositoryWorkspace branch ancestry and ReadinessScanner's legacy-work discovery. A fresh
// workspace handed to CatchUpCoordinator must recover nested leaf bindings from the ledger.
// Criterion 6 (updating existing tests' branch expectations) is a diff-review criterion,
// not a runtime/source-text assertion. Repository fixtures use only local git, never the network.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_88Tests {
    @Test
    func firstBuildCreatesTheRequirementAtCurrentMainAndRecordsItOnlyOnce() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let leaf = try await f.add("internal-single-leaf", ticket: "GH-120", phase: .specified, build: false)
        _ = try await f.round()
        #expect(await f.workspace.creations.isEmpty, "Adoption alone must not create a requirement branch")
        await f.workspace.moveMain(to: "main-at-build")
        try await f.openBuild(leaf.id)

        _ = try await f.until { $0.nodes[leaf.id]?.testsDigest != nil }
        _ = try await f.round()

        let creations = await f.workspace.creations
        #expect(creations == [.init(branch: "agentos/GH-120", from: "main-at-build")])
        let records = await f.ledger.allRecords().filter {
            guard $0.event.node == leaf.id else { return false }
            guard case .requirementBranchCreated(let branch, let from) = $0.event.kind else { return false }
            return branch == "agentos/GH-120" && from == "main-at-build"
        }
        #expect(records.count == 1, "The durable creation record identifies both branch and starting commit")
    }

    @Test
    func directAndDeepLeavesStartAndLandOnTheTopLevelTicketsBranch() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let root = try await f.add("root-not-a-ticket-key", ticket: "GH-121", kind: .composite, phase: .split)
        let child = try await f.add("nested-composite", ticket: "GH-122", parent: root.id, kind: .composite, phase: .split)
        let direct = try await f.add("direct", ticket: "GH-123", parent: root.id, phase: .specified)
        let deep = try await f.add("deep", ticket: "GH-124", parent: child.id, phase: .specified)
        let other = try await f.add("other-root", ticket: "GH-125", kind: .composite, phase: .split)
        let otherLeaf = try await f.add("other-leaf", ticket: "GH-126", parent: other.id, phase: .specified)

        _ = try await f.until { state in
            [direct, deep, otherLeaf].allSatisfy { state.nodes[$0.id]?.phase == .proven }
        }
        _ = try await f.round()

        let calls = await f.workspace.operations
        for leaf in [direct, deep] {
            #expect(calls.contains(.init(action: .start, node: leaf.id, branch: "agentos/GH-121")))
            #expect(calls.contains(.init(action: .rebase, node: leaf.id, branch: "agentos/GH-121")))
            #expect(calls.contains(.init(action: .land, node: leaf.id, branch: "agentos/GH-121")))
            let full = await f.checks.calls.filter { $0.node == leaf.id && $0.only == nil }
            #expect(!full.isEmpty, "Landing runs all tests and checks, not just the leaf suite")
            #expect(full.allSatisfy { $0.base == "agentos/GH-121" })
            #expect(f.workspace.branch(for: leaf.id) == "agentos/leaf/\(leaf.id)")
        }
        let creations = await f.workspace.creations
        #expect(creations.count == 2)
        #expect(Set(creations.map(\.branch)) == ["agentos/GH-121", "agentos/GH-125"])
        let records = await f.ledger.allRecords().filter {
            if case .requirementBranchCreated = $0.event.kind { return true }
            return false
        }
        #expect(records.count == 2)
        for (requirement, branch) in [(root, "agentos/GH-121"), (other, "agentos/GH-125")] {
            let own = records.filter { $0.event.node == requirement.id }
            #expect(own.count == 1, "Several leaves share one durable creation record on the top-level node")
            if let event = own.first?.event, case .requirementBranchCreated(let name, let from) = event.kind {
                #expect(name == branch)
                #expect(from == "main-0")
            }
        }
        #expect(!calls.contains { $0.branch == "agentos/GH-122" || $0.branch == "agentos/main" })
    }

    @Test
    func aGatedCompositeWaitsForItsFirstLeafAndReusesItsBranchForALaterLeaf() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let root = try await f.add("gated-root", ticket: "GH-127", kind: .composite, phase: .split, build: false)
        let first = try await f.add("gated-first", ticket: "GH-128", parent: root.id, phase: .specified, build: false)
        let later = try await f.add("gated-later", ticket: "GH-129", parent: root.id, phase: .specified, build: false)

        _ = try await f.round()

        #expect(await f.workspace.creations.isEmpty)
        #expect(await f.workspace.operations.isEmpty, "No leaf has permission to start building yet")
        #expect(await f.ledger.allRecords().allSatisfy {
            if case .requirementBranchCreated = $0.event.kind { return false }
            return true
        })
        await f.workspace.moveMain(to: "main-at-first-leaf")
        try await f.openBuild(first.id)
        _ = try await f.until { $0.nodes[first.id]?.phase == .proven }
        let firstCommit = try #require(await f.ledger.workingState().nodes[first.id]?.landedCommit)
        #expect(await f.workspace.operations.allSatisfy { $0.node != later.id })

        await f.workspace.moveMain(to: "main-before-later-leaf")
        try await f.openBuild(later.id)
        _ = try await f.until { $0.nodes[later.id]?.phase == .proven }
        _ = try await f.round()

        #expect(await f.workspace.creations == [.init(branch: "agentos/GH-127", from: "main-at-first-leaf")])
        let starts = await f.workspace.starts
        #expect(starts.first { $0.node == first.id }?.commit == "main-at-first-leaf")
        #expect(starts.first { $0.node == later.id }?.base == "agentos/GH-127")
        #expect(await f.workspace.commits(on: "agentos/GH-127").contains(firstCommit))
        let records = await f.ledger.allRecords().filter {
            if case .requirementBranchCreated = $0.event.kind { return true }
            return false
        }
        #expect(records.count == 1)
        #expect(records.first?.event.node == root.id)
    }

    @Test
    func separateRequirementsDoNotInheritEachOthersLandedCommits() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let first = try await f.add("first", ticket: "GH-130", phase: .specified)
        _ = try await f.until { $0.nodes[first.id]?.phase == .proven }
        let firstCommit = try #require(await f.ledger.workingState().nodes[first.id]?.landedCommit)
        let second = try await f.add("second", ticket: "GH-131", phase: .specified)
        _ = try await f.until { $0.nodes[second.id]?.phase == .proven }
        let secondCommit = try #require(await f.ledger.workingState().nodes[second.id]?.landedCommit)

        #expect(await f.workspace.commits(on: "agentos/GH-130") == ["main-0", firstCommit])
        #expect(await f.workspace.commits(on: "agentos/GH-131") == ["main-0", secondCommit])
    }

    @Test
    func landingDiagnosisRerunsAgainstTheSameRequirementsLatestTipWithoutTheChange() async throws {
        let f = try Fixture(diagnose: true)
        defer { f.cleanUp() }
        let root = try await f.add("diagnosis-root", ticket: "GH-140", kind: .composite, phase: .split)
        let leaf = try await f.add("diagnosis-leaf", ticket: "GH-141", parent: root.id, phase: .landing)
        await f.workspace.seedBranch("agentos/GH-140", commits: ["main-0", "latest-own-requirement"])
        await f.workspace.seedBranch("agentos/GH-199", commits: ["main-0", "other-requirement"])
        try await f.ledger.append([
            LedgerEvent(node: root.id, by: .reconciler,
                        kind: .requirementBranchCreated(branch: "agentos/GH-140", from: "main-0")),
        ])
        #expect(await f.workspace.preparations.isEmpty)

        _ = try await f.round()

        #expect(await f.workspace.preparations.contains {
            $0.requirement == NodeIdentity(ticketKey: "GH-140", nodeID: root.id) && $0.leaves.contains(leaf.id)
        }, "The reconciler must restore the leaf binding even when branch creation is already in the ledger")
        let calls = await f.checks.calls.filter { $0.node == leaf.id }
        #expect(calls.filter { $0.only == nil && !$0.snapshot }.count == 2, "Rerun the whole landing check first")
        #expect(calls.prefix(2).allSatisfy { $0.only == nil && !$0.snapshot })
        let withChange = calls.filter { $0.only == "ExistingBehaviorTests" && !$0.snapshot }
        let withoutChange = calls.filter { $0.only == "ExistingBehaviorTests" && $0.snapshot }
        #expect(withChange.count == 1)
        #expect(withoutChange.count == 1)
        #expect(calls.allSatisfy { $0.base == "agentos/GH-140" })
        #expect(withoutChange.first?.commit == "latest-own-requirement")
        #expect(withChange.first?.commit != withoutChange.first?.commit)
        #expect(await f.workspace.removedSnapshots.count == 1)
        let node = try #require(await f.ledger.workingState().nodes[leaf.id])
        #expect(node.failedAttempts == 0)
        #expect(node.landedCommit == nil)
        let report = await f.tracker.comments.joined(separator: "\n")
        #expect(report.contains("agentos/GH-140"))
        #expect(!report.contains("agentos/main"), "Diagnostic advice must name the branch a person can fix")
    }

    @Test
    func anAlreadyBuildingLeafLandsOnItsNewRequirementWithoutMigratingLegacyWork() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let root = try await f.add("upgrade-root", ticket: "GH-150", kind: .composite, phase: .split)
        let leaf = try await f.add("pre-upgrade-leaf", ticket: "GH-151", parent: root.id, phase: .landing)
        let legacy = ["main-0", "legacy-only-commit"]
        await f.workspace.seedBranch("agentos/main", commits: legacy)
        #expect(await f.workspace.preparations.isEmpty)

        _ = try await f.until { $0.nodes[leaf.id]?.phase == .proven }

        #expect(await f.workspace.preparations.contains {
            $0.requirement == NodeIdentity(ticketKey: "GH-150", nodeID: root.id) && $0.leaves.contains(leaf.id)
        }, "An in-progress leaf must be bound by the reconciler, not by fixture setup")
        #expect(await f.workspace.creations == [.init(branch: "agentos/GH-150", from: "main-0")])
        let records = await f.ledger.allRecords().filter {
            guard $0.event.node == root.id else { return false }
            if case .requirementBranchCreated(let branch, let from) = $0.event.kind {
                return branch == "agentos/GH-150" && from == "main-0"
            }
            return false
        }
        #expect(records.count == 1, "Upgrading records the new requirement branch on the original requirement")
        let landed = try #require(await f.ledger.workingState().nodes[leaf.id]?.landedCommit)
        #expect(await f.workspace.commits(on: "agentos/GH-150") == ["main-0", landed])
        #expect(await f.workspace.commits(on: "agentos/main") == legacy)
        #expect(await f.workspace.operations.allSatisfy { $0.branch != "agentos/main" })
    }

    @Test
    func catchUpUpdatesRequirementBranchesAndRebasesOnlyTheirEligibleLeaves() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let a = try await f.add("catch-up-a", ticket: "GH-160", kind: .composite, phase: .split)
        let nested = try await f.add("catch-up-child", ticket: "GH-161", parent: a.id, kind: .composite, phase: .split)
        let b = try await f.add("catch-up-b", ticket: "GH-170", kind: .composite, phase: .split)
        let idleA = try await f.add("idle-a", ticket: "GH-162", parent: nested.id, phase: .ready)
        let idleB = try await f.add("idle-b", ticket: "GH-171", parent: b.id, phase: .ready)
        let busy = try await f.add("busy-a", ticket: "GH-163", parent: a.id, phase: .ready)
        let claimed = try await f.add("claimed-b", ticket: "GH-172", parent: b.id, phase: .building)
        let proven = try await f.add("proven-a", ticket: "GH-164", parent: a.id, phase: .proven)
        try await f.ledger.append([
            LedgerEvent(node: claimed.id, by: .reconciler, kind: .runStarted(run: "held-implementer", role: .implementer)),
        ])
        await f.workspace.seedBranch("agentos/GH-160", commits: ["main-0", "a-landed"])
        await f.workspace.seedBranch("agentos/GH-170", commits: ["main-0", "b-landed"])
        await f.workspace.seedBranch("agentos/main", commits: ["main-0", "legacy-only"])
        try await f.ledger.append([
            LedgerEvent(node: a.id, by: .reconciler,
                        kind: .requirementBranchCreated(branch: "agentos/GH-160", from: "main-0")),
            LedgerEvent(node: b.id, by: .reconciler,
                        kind: .requirementBranchCreated(branch: "agentos/GH-170", from: "main-0")),
        ])
        await f.workspace.moveMain(to: "main-new")
        let result = try await f.workspace.catchUpRequirements(
            in: await f.ledger.workingState(), busy: [busy.id]
        )

        #expect(result[a.id]?.rebased.contains(idleA.id) == true)
        #expect(result[b.id]?.rebased.contains(idleB.id) == true)
        for (root, leaf) in [(a, idleA), (b, idleB)] {
            #expect(await f.workspace.preparations.contains {
                $0.requirement.nodeID == root.id && $0.leaves.contains(leaf.id)
            }, "Catch-up must recover the leaf binding from the ledger")
        }
        let calls = await f.workspace.operations
        #expect(calls.contains(.init(action: .catchUp, node: a.id, branch: "agentos/GH-160")))
        #expect(calls.contains(.init(action: .catchUp, node: b.id, branch: "agentos/GH-170")))
        #expect(calls.contains(.init(action: .rebase, node: idleA.id, branch: "agentos/GH-160")))
        #expect(calls.contains(.init(action: .rebase, node: idleB.id, branch: "agentos/GH-170")))
        #expect(!calls.contains { [busy.id, claimed.id, proven.id].contains($0.node) && $0.action == .rebase })
        #expect(!calls.contains { $0.branch == "agentos/main" || $0.branch == "agentos/GH-161" })
        #expect(await f.workspace.commits(on: "agentos/GH-160") == ["main-0", "a-landed", "main-new"])
        #expect(await f.workspace.commits(on: "agentos/GH-170") == ["main-0", "b-landed", "main-new"])
        #expect(await f.workspace.commits(on: "agentos/main") == ["main-0", "legacy-only"])
    }

    @Test(arguments: ["custom/landing", "main"])
    func landingBranchConfigIsWarnedAboutAndHasNoEffect(_ configured: String) throws {
        let normal = Self.snapshot()
        var retired = normal
        retired.contents[RepoConfig.path] = Self.config(landing: configured)
        let baseline = Baseline(commit: normal.commit, passed: true, summary: "passed", seconds: 1, log: nil)
        let standard = ReadinessRules.assess(normal, harness: HarnessSettings(), baseline: baseline)
        let actual = ReadinessRules.assess(retired, harness: HarnessSettings(), baseline: baseline)

        let warning = actual.findings.first {
            $0.severity == .warning && Self.words($0).contains("landing.branch")
        }
        #expect(warning != nil)
        if let warning {
            #expect(Self.words(warning).contains("ignored"))
            #expect(Self.words(warning).contains("no effect"))
        }
        #expect(actual.policy.policy == standard.policy.policy)
        #expect(actual.policy.landingBranch == standard.policy.landingBranch)
        #expect(!actual.findings.contains { $0.check == "config.policy" && $0.severity == .blocker })
    }

    @Test(arguments: [0, 1, 3])
    func onlyUnmergedLegacyWorkGetsAManualMergeWarning(_ commitsAhead: Int) {
        var repo = Self.snapshot()
        repo.legacyLandingCommitsAhead = commitsAhead

        let findings = ReadinessRules.findings(for: repo)
        let warnings = findings.filter { $0.severity == .warning && Self.words($0).contains("agentos/main") }

        #expect(warnings.count == (commitsAhead > 0 ? 1 : 0))
        if let warning = warnings.first {
            let text = Self.words(warning)
            #expect(text.contains("only"))
            #expect(text.contains("merge"))
            #expect(text.contains("into main") || text.contains("into `main`"))
            #expect(!text.contains("automatically migrate"))
        }
    }

    private static func words(_ finding: Finding) -> String {
        "\(finding.title) \(finding.detail) \(finding.suggestion ?? "")".lowercased()
    }

    private static func config(landing: String? = nil) -> String {
        let extra = landing.map { #", "landing": {"branch": "\#($0)"}"# } ?? ""
        return #"{"test":{"command":"swift test","only":"--filter {suite}"},"leafTests":{"target":"AppTests","folder":"Tests/AppTests"}\#(extra)}"#
    }

    private static func snapshot() -> RepositorySnapshot {
        let files = [
            "README.md": "# App",
            "AGENTS.md": "Build with swift build; test with swift test.",
            "CONTRIBUTING.md": "Definition of Done: tests pass.",
            "CODEOWNERS": "* @maintainers",
            "Package.swift": #".testTarget(name: "AppTests")"#,
            RepoConfig.path: Self.config(),
        ]
        return RepositorySnapshot(branch: "main", commit: "main-0", files: Array(files.keys), contents: files)
    }
}
