import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

extension GH_88Tests {
    @Test
    func realRequirementBranchStartsAtTheCurrentMainWithoutChangingOrPushingDeveloperWork() async throws {
        let f = try await RepositoryFixture()
        defer { f.cleanUp() }
        let checkout = try await f.revision("HEAD")
        try "uncommitted personal work\n".write(to: f.repo.appending(path: "base.txt"), atomically: true, encoding: .utf8)
        let status = try await RepositoryFixture.git(["status", "--porcelain"], in: f.repo)

        try await f.workspace.prepare()
        #expect(try await !f.branches().contains("agentos/main"), "Preparing a repository must not create the retired branch")
        let currentMain = try await f.commit(on: "main", file: "new-main.txt", contents: "current main\n")
        #expect(currentMain != f.initialMain)
        let requirement = NodeIdentity(ticketKey: "GH-880", nodeID: "internal-id-not-ticket-key")

        let createdFrom = try await f.workspace.prepareRequirementBranch(for: requirement, leaves: [requirement.nodeID])

        #expect(createdFrom == currentMain)
        #expect(try await f.revision("main") == currentMain)
        #expect(try await f.branches().contains("agentos/GH-880"))
        if try await f.branches().contains("agentos/GH-880") {
            #expect(try await f.revision("agentos/GH-880") == currentMain)
            let newerMain = try await f.commit(on: "main", file: "later-main.txt", contents: "later main\n")
            #expect(try await f.workspace.prepareRequirementBranch(for: requirement, leaves: [requirement.nodeID]) == nil)
            #expect(try await f.revision("agentos/GH-880") == currentMain, "Preparing again must not recreate or move the branch")
            #expect(try await f.revision("main") == newerMain)
        }
        try await f.assertPersonalCheckout(head: checkout, status: status)
        #expect(try String(contentsOf: f.repo.appending(path: "base.txt"), encoding: .utf8) == "uncommitted personal work\n")
        try await f.assertNoPush()
    }

    @Test
    func realLeafBranchesStartAndLandOnOnlyTheirOwnRequirementAndSnapshotsReadItsLatestTip() async throws {
        let f = try await RepositoryFixture()
        defer { f.cleanUp() }
        try await f.workspace.prepare()
        let a = NodeIdentity(ticketKey: "GH-881", nodeID: "root-a")
        let b = NodeIdentity(ticketKey: "GH-882", nodeID: "root-b")
        _ = try await f.workspace.prepareRequirementBranch(for: a, leaves: ["direct-a", "deep-a"])
        _ = try await f.workspace.prepareRequirementBranch(for: b, leaves: ["leaf-b"])
        // Keep useful failures against the empty API placeholders instead of failing in fixture setup.
        try #require(try await f.branches().isSuperset(of: ["agentos/GH-881", "agentos/GH-882"]))
        let main = try await f.revision("main")
        let directoryA = try await f.workspace.createWorktree(for: "direct-a")
        #expect(try await f.workspace.head(of: directoryA) == main)
        #expect(f.workspace.branch(for: "direct-a") == "agentos/leaf/direct-a")
        try "A\n".write(to: directoryA.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let commitA = try #require(try await f.workspace.commitAll(in: directoryA, message: "A", author: "implementer"))
        guard case .clean = try await f.workspace.rebaseOntoMain(directoryA) else {
            Issue.record("The first requirement has no conflicting work")
            return
        }
        let landedA = try await f.workspace.landOnMain("direct-a")
        #expect(landedA == commitA)

        let directoryB = try await f.workspace.createWorktree(for: "leaf-b")
        #expect(try await f.workspace.head(of: directoryB) == main, "Another requirement's landing must not become this leaf's base")
        let deepA = try await f.workspace.createWorktree(for: "deep-a")
        #expect(try await f.workspace.head(of: deepA) == landedA)
        try "B\n".write(to: directoryB.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        _ = try await f.workspace.commitAll(in: directoryB, message: "B", author: "implementer")
        guard case .clean = try await f.workspace.rebaseOntoMain(directoryB) else {
            Issue.record("Separate requirements must not introduce conflicts with one another")
            return
        }
        let landedB = try await f.workspace.landOnMain("leaf-b")
        #expect(try await f.contains(landedA, on: "agentos/GH-881"))
        #expect(try await !f.contains(landedB, on: "agentos/GH-881"))
        #expect(try await f.contains(landedB, on: "agentos/GH-882"))
        #expect(try await !f.contains(landedA, on: "agentos/GH-882"))
        #expect(try await RepositoryFixture.git(["rev-list", "\(main)..agentos/GH-881"], in: f.repo) == landedA)
        #expect(try await RepositoryFixture.git(["rev-list", "\(main)..agentos/GH-882"], in: f.repo) == landedB)
        let snapshot = try #require(try await f.workspace.createSnapshot(for: "deep-a"))
        #expect(try await f.workspace.head(of: snapshot) == landedA)
        #expect(!FileManager.default.fileExists(atPath: snapshot.appending(path: "b.txt").path))
        await f.workspace.removeSnapshot(snapshot)
        #expect(try await f.revision("main") == main)
        try await f.assertPersonalCheckout(head: f.initialMain, status: "")
        try await f.assertNoPush()
    }

    @Test
    func realCatchUpCoordinatorRecoversNestedLeafBindingsAndRebasesOntoTheCorrectRequirement() async throws {
        let f = try await RepositoryFixture()
        defer { f.cleanUp() }
        let ledger = try Ledger()
        try await f.workspace.prepare()
        let a = NodeIdentity(ticketKey: "GH-883", nodeID: "root-a")
        let b = NodeIdentity(ticketKey: "GH-884", nodeID: "root-b")
        for (requirement, leaves) in [(a, ["deep-a", "busy-a", "proven-a"]), (b, ["idle-b", "claimed-b"])] {
            let spec = NodeSpec(id: requirement.nodeID, parent: nil, kind: .composite, title: requirement.ticketKey,
                                intent: "Keep requirement work separate", acceptanceCriteria: ["Catch up locally"])
            try await ledger.append([
                LedgerEvent(node: spec.id, by: .human("Developer"), kind: .nodeCreated(spec: spec, ticket: requirement.ticketKey)),
                LedgerEvent(node: spec.id, by: .human("Developer"), kind: .gateOpened(.build)),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .split)),
            ])
            if let from = try await f.workspace.prepareRequirementBranch(for: requirement, leaves: leaves) {
                try await ledger.append([
                    LedgerEvent(node: spec.id, by: .reconciler,
                                kind: .requirementBranchCreated(branch: "agentos/\(requirement.ticketKey)", from: from)),
                ])
            }
        }
        try #require(try await f.branches().isSuperset(of: ["agentos/GH-883", "agentos/GH-884"]))
        let child = NodeSpec(id: "child-composite", parent: a.nodeID, kind: .composite, title: "Nested work",
                             intent: "Nested leaves share the root branch", acceptanceCriteria: ["No child branch"])
        try await ledger.append([
            LedgerEvent(node: child.id, by: .human("Developer"), kind: .nodeCreated(spec: child, ticket: "GH-885")),
            LedgerEvent(node: child.id, by: .reconciler, kind: .phaseChanged(to: .split)),
        ])
        let ownA = try await f.commit(on: "agentos/GH-883", file: "only-a.txt", contents: "A's landed work\n")
        let ownB = try await f.commit(on: "agentos/GH-884", file: "only-b.txt", contents: "B's landed work\n")
        var oldHeads: [NodeID: String] = [:]
        for (id, parent, phase) in [
            ("deep-a", child.id, Phase.ready), ("idle-b", b.nodeID, .ready),
            ("busy-a", a.nodeID, .ready), ("claimed-b", b.nodeID, .building), ("proven-a", a.nodeID, .proven),
        ] {
            let spec = NodeSpec(id: id, parent: parent, kind: .leaf, title: id, intent: "Retain my changes",
                                acceptanceCriteria: ["Rebase on my requirement"])
            oldHeads[id] = try await f.leafCommit(spec, file: "\(id).txt")
            let tests = f.workspace.worktree(for: id).appending(path: f.workspace.testFolder(for: spec))
            try await ledger.append([
                LedgerEvent(node: id, by: .human("Developer"), kind: .nodeCreated(spec: spec, ticket: "ticket-\(id)")),
                LedgerEvent(node: id, by: .reconciler, kind: .testsFixed(digest: Hashing.digest(of: tests))),
                LedgerEvent(node: id, by: .reconciler, kind: .phaseChanged(to: phase)),
            ])
        }
        try await ledger.append([
            LedgerEvent(node: "claimed-b", by: .reconciler, kind: .runStarted(run: "held-run", role: .implementer)),
        ])
        try await RepositoryFixture.git(["branch", "-f", "agentos/main", "main"], in: f.repo)
        let legacy = try await f.commit(on: "agentos/main", file: "legacy-only.txt", contents: "Do not migrate\n")
        let main = try await f.commit(on: "main", file: "upstream.txt", contents: "new main\n")
        try await ledger.record(Baseline(commit: main, passed: true, summary: "passed", seconds: 0, log: nil))

        // Setup bindings must not stand in for the coordinator's ledger-to-workspace wiring.
        let workspace = try f.freshWorkspace()
        let coordinator = CatchUpCoordinator(workspace: workspace, ledger: ledger, landingQueue: LandingQueue())
        _ = await coordinator.reconcile(busy: ["busy-a"])

        for (id, branch, own, other) in [
            ("deep-a", "agentos/GH-883", ownA, ownB), ("idle-b", "agentos/GH-884", ownB, ownA),
        ] {
            #expect(try await f.contains(main, on: branch))
            #expect(try await f.contains(main, on: workspace.branch(for: id)))
            let requirementTip = try await f.revision(branch)
            #expect(try await f.contains(requirementTip, on: workspace.branch(for: id)),
                    "A nested leaf must rebase on its requirement tip, not directly on main or another requirement")
            #expect(try await f.contains(own, on: branch), "Catch-up merges must preserve landed work")
            #expect(try await !f.contains(other, on: workspace.branch(for: id)))
            #expect(try await !f.contains(legacy, on: branch), "Legacy work must wait for a person's merge into main")
            #expect(try await !f.contains(legacy, on: workspace.branch(for: id)))
            #expect(try String(contentsOf: workspace.worktree(for: id).appending(path: "\(id).txt"), encoding: .utf8) == "\(id)\n")
        }
        for id in ["busy-a", "claimed-b", "proven-a"] {
            #expect(try await f.revision(workspace.branch(for: id)) == oldHeads[id])
        }
        #expect(try await f.revision("agentos/main") == legacy)
        #expect(try await !f.branches().contains("agentos/GH-885"))
        #expect(try await f.revision("main") == main)
        try await f.assertPersonalCheckout(head: f.initialMain, status: "")
        try await f.assertNoPush()
    }

    @Test(arguments: [LegacyBranch.absent, .containedInMain, .unmerged])
    func realReadinessScanDiscoversOnlyLegacyCommitsMissingFromMain(_ legacy: LegacyBranch) async throws {
        let f = try await RepositoryFixture()
        defer { f.cleanUp() }
        if legacy != .absent {
            try await RepositoryFixture.git(["branch", "agentos/main", "main"], in: f.repo)
            let commit = try await f.commit(on: "agentos/main", file: "old-work.txt", contents: "legacy work\n")
            if legacy == .containedInMain {
                try await RepositoryFixture.git(["update-ref", "refs/heads/main", commit, f.initialMain], in: f.repo)
            }
        }
        let main = try await f.revision("main")
        let scan = await ReadinessScanner().scan(f.repo, baseline: Baseline(
            commit: main, passed: true, summary: "passed", seconds: 0, log: nil
        ))
        #expect(scan.root?.resolvingSymlinksInPath() == f.repo.resolvingSymlinksInPath())
        let warnings = scan.scan.findings.filter {
            $0.severity == .warning && "\($0.title) \($0.detail) \($0.suggestion ?? "")".contains("agentos/main")
        }
        #expect(warnings.count == (legacy == .unmerged ? 1 : 0))
        if let warning = warnings.first {
            let message = "\(warning.title) \(warning.detail) \(warning.suggestion ?? "")".lowercased()
            #expect(message.contains("only"))
            #expect(message.contains("merge"))
            #expect(message.contains("into main") || message.contains("into `main`"))
        }
        #expect(try await f.revision("main") == main)
        try await f.assertPersonalCheckout(head: f.initialMain, status: "")
        try await f.assertNoPush()
    }

    enum LegacyBranch: Sendable { case absent, containedInMain, unmerged }
}
