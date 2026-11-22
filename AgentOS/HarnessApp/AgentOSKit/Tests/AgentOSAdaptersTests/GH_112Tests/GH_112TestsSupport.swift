import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Synchronization
import Testing

extension GH_112Tests {
    static let repository = "acceptance/reverification"

    enum TipChange: CaseIterable, Sendable {
        case catchUp, laterLeafLanding, personCommit, personResolvingCatchUpConflict
    }

    struct Root: Sendable {
        let spec: NodeSpec
        let ticket: String
        let pullRequest: Int?
        var id: NodeID { spec.id }
        var branch: String { "agentos/\(ticket)" }
        var identity: NodeIdentity { NodeIdentity(ticketKey: ticket, nodeID: id) }
    }

    static func evidence(_ root: Root, commit: String, passed: Bool = true) -> Evidence {
        Evidence(check: "final requirement verification", passed: passed, summary: "Seeded verification",
                 specHash: root.spec.specHash, builtBy: "seed-builder", checkedBy: "seed-verifier",
                 artifactPath: "memory/seed.log", artifactSHA256: "seed-digest", commit: commit)
    }

    static func policy() -> EffectivePolicy {
        var harness = HarnessSettings()
        harness.pullRequests = true
        harness.maxParallelAgents = 4
        return EffectivePolicy.resolve(harness: harness, repo: nil, defaultBranch: "main")
    }

    static func replay(_ ledger: Ledger) async throws -> Ledger {
        let records = try JSONDecoder().decode(
            [RecordedEvent].self, from: JSONEncoder().encode(await ledger.allRecords()))
        let store = InMemoryLedgerStore()
        store.append(records)
        return try Ledger(store: store)
    }

    static func whileFirstCheckIsHeld(
        _ f: Fixture, drain: Bool = true, inspect: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withHangGuard("GH-112 gated verification") {
            try await withThrowingTaskGroup(of: Void.self) { group in
                let roundEnded = TestGate()
                group.addTask {
                    defer { roundEnded.open() }
                    if drain {
                        try await f.drain()
                    } else {
                        while true {
                            let report = await f.reconciler.runRound(waitForAgents: true)
                            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                            if f.checks.started.isOpen {
                                await f.reconciler.waitForAgents()
                                return
                            }
                            if report.isIdle { return }
                        }
                    }
                }
                defer { f.checks.release.open() }
                try await eventually("Verification started or its initiating round completed") {
                    f.checks.started.isOpen || roundEnded.isOpen
                }
                try #require(f.checks.started.isOpen,
                             "An unverified current requirement tip must start final verification without a signal.")
                try await inspect()
                f.checks.release.open()
                try await group.waitForAll()
            }
        }
    }

    static func expectPushedAndPending(_ f: Fixture, root: Root, commit: String) async throws {
        let push = try #require(await f.git.pushes.first { $0.commit == commit })
        try Self.expectSafePush(push.arguments, branch: root.branch)
        let statuses = await f.github.statuses.filter { $0.commit == commit }
        #expect(statuses.contains(Status(commit: commit, state: "pending", description: "Waiting for final verification")))
        #expect(statuses.contains(Status(commit: commit, state: "pending", description: "Final verification running")))
        #expect(await f.ledger.workingState().nodes[root.id]?.publishedCommit == commit)
    }

    static func expectLifecycle(_ f: Fixture, root: Root, commit: String, passed: Bool) async throws {
        let events = await f.trace.events
        let push = try #require(events.firstIndex(of: .push(root.branch, commit)))
        let waiting = try #require(events.firstIndex(of: .status(commit, "pending", "Waiting for final verification")))
        let running = try #require(events.firstIndex(of: .status(commit, "pending", "Final verification running")))
        let start = try #require(events.firstIndex(of: .checkStarted(commit)))
        let finish = try #require(events.firstIndex(of: .checkFinished(commit, passed)))
        let result = try #require(events.firstIndex {
            if case .status(let sha, let state, _) = $0 {
                return sha == commit && state == (passed ? "success" : "failure")
            }
            return false
        })
        #expect(push < waiting && waiting < running && running < start && start < finish && finish < result)
        #expect(await f.github.unexpected.isEmpty)
        #expect(await f.github.mutations.contains { $0.contains("/merge") } == false)
    }

    static func expectVerification(_ f: Fixture, root: Root, commit: String, passed: Bool) async throws {
        let result = try #require(await f.ledger.workingState().nodes[root.id]?.requirementVerification)
        #expect(result.commit == commit)
        #expect(result.passed == passed)
        #expect(await f.results(for: root).contains { $0.commit == commit && $0.passed == passed })
        let log = try #require(f.artifacts.contents(of: result.artifactPath))
        #expect(Hashing.sha256(log) == result.artifactSHA256)
        #expect(String(decoding: log, as: UTF8.self).contains(commit))
        #expect(await f.checks.calls.contains { $0.commit == commit && $0.suite == nil })
    }

    static func expectSafePush(_ arguments: [String], branch: String) throws {
        #expect(arguments.first == "push")
        #expect(!arguments.contains {
            $0.hasPrefix("--force") || ["-f", "--all", "--mirror", "--tags", "--delete"].contains($0)
                || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("f"))
        })
        let origin = try #require(arguments.firstIndex(of: "origin"))
        let refs = arguments.dropFirst(origin + 1).filter { !$0.hasPrefix("-") }
        try #require(refs.count == 1)
        let destinations = refs[refs.startIndex].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        #expect((1...2).contains(destinations.count))
        #expect(destinations.allSatisfy { $0 == branch || $0 == "refs/heads/\(branch)" })
    }

    final class Fixture: Sendable {
        let ledger: Ledger
        let roots: [Root]
        let workspace: Branches
        let trace: Trace
        let checks: Checks
        let git: Git
        let github: GitHub
        let tracker: Tracker
        let agents: Agents
        let artifacts: Artifacts
        let reconciler: Reconciler

        private init(ledger: Ledger, roots: [Root], workspace: Branches, trace: Trace,
                     checks: Checks, git: Git, github: GitHub) {
            self.ledger = ledger
            self.roots = roots
            self.workspace = workspace
            self.trace = trace
            self.checks = checks
            self.git = git
            self.github = github
            let tracker = Tracker()
            let agents = Agents()
            let artifacts = Artifacts()
            self.tracker = tracker
            self.agents = agents
            self.artifacts = artifacts
            let publisher = PullRequestPublicationCoordinator(
                ledger: ledger, tracker: tracker, repository: GH_112Tests.repository,
                policy: GH_112Tests.policy(), transport: github, git: { try await git.run($0) })
            self.reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: External(), workspace: workspace,
                artifacts: artifacts, checks: checks,
                team: AgentTeam(name: "GH-112 no agent rework", decomposer: agents, testAuthor: agents, implementer: agents),
                policy: GH_112Tests.policy().policy, requirementBranches: workspace,
                publisher: publisher, pullRequests: publisher)
        }

        static func make(pullRequests: [Int?] = [112]) async throws -> Fixture {
            let ledger = try Ledger()
            let trace = Trace()
            let workspace = Branches()
            let roots = pullRequests.enumerated().map { index, number in
                let ticket = "GH-112-\(index)"
                return Root(spec: NodeSpec(
                    id: "wn-\(ticket)", parent: nil, kind: .composite, title: "Reverify \(ticket)",
                    intent: "Keep the current requirement tip verified",
                    acceptanceCriteria: ["The current tip has a final verification result"]), ticket: ticket, pullRequest: number)
            }
            let checks = Checks(workspace: workspace, trace: trace)
            let git = Git(workspace: workspace, trace: trace)
            let github = GitHub(trace: trace, pullRequests: roots)
            let fixture = Fixture(ledger: ledger, roots: roots, workspace: workspace,
                                  trace: trace, checks: checks, git: git, github: github)
            for root in roots {
                let initial = "initial-\(root.ticket)"
                await workspace.add(root, commit: initial)
                await fixture.tracker.add(Ticket(
                    key: root.ticket, title: root.spec.title, description: root.spec.intent,
                    acceptanceCriteria: root.spec.acceptanceCriteria, createdBy: .human("Owner")))
                var events: [EventKind] = [
                    .nodeCreated(spec: root.spec, ticket: root.ticket), .phaseChanged(to: .proven),
                    .landed(commit: initial), .requirementBranchCreated(branch: root.branch, from: "main-base"),
                    .requirementBranchObserved(branch: root.branch, tip: initial, main: "main-base", containedInMain: false),
                ]
                if let number = root.pullRequest {
                    events += [
                        .requirementVerificationStarted,
                        .requirementVerificationFinished(GH_112Tests.evidence(root, commit: initial)),
                        .requirementPushed(branch: root.branch, commit: initial),
                        .requirementPullRequestOpened(number: number, url: "https://github.com/acceptance/reverification/pull/\(number)"),
                        .requirementPublicationFinished(commit: initial),
                    ]
                }
                try await ledger.append(events.map { kind in
                    let by: Participant
                    if case .requirementVerificationFinished(let evidence) = kind {
                        by = .agent(run: evidence.checkedBy, role: .verifier)
                    } else {
                        by = .reconciler
                    }
                    return LedgerEvent(node: root.id, by: by, kind: kind)
                })
                let leaf = NodeSpec(id: root.id + "-leaf", parent: root.id, kind: .leaf,
                                    title: "Landed leaf", intent: "Complete part of the requirement",
                                    acceptanceCriteria: ["The leaf is proven"])
                try await ledger.append([
                    LedgerEvent(node: leaf.id, by: .reconciler, kind: .nodeCreated(spec: leaf, ticket: root.ticket + "-leaf")),
                    LedgerEvent(node: leaf.id, by: .reconciler, kind: .landed(commit: initial)),
                    LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
                ])
            }
            try await fixture.baseline("main-base")
            return fixture
        }

        func publisher(ledger replacement: Ledger? = nil) -> PullRequestPublicationCoordinator {
            PullRequestPublicationCoordinator(
                ledger: replacement ?? ledger, tracker: tracker, repository: GH_112Tests.repository,
                policy: GH_112Tests.policy(), transport: github,
                git: { [git] in try await git.run($0) })
        }

        func makeReconciler(ledger replacement: Ledger? = nil) -> Reconciler {
            let publisher = publisher(ledger: replacement)
            return Reconciler(
                ledger: replacement ?? ledger, tracker: tracker, external: External(), workspace: workspace,
                artifacts: artifacts, checks: checks,
                team: AgentTeam(name: "GH-112 no agent rework", decomposer: agents, testAuthor: agents, implementer: agents),
                policy: GH_112Tests.policy().policy, requirementBranches: workspace,
                publisher: publisher, pullRequests: publisher)
        }

        func baseline(_ commit: String) async throws {
            try await ledger.append([LedgerEvent(node: nil, by: .reconciler, kind: .baselineChecked(
                Baseline(commit: commit, passed: true, summary: "Passed", seconds: 0, log: nil)))])
        }

        func changeTip(of root: Root, by change: TipChange) async throws -> String {
            let new = await workspace.nextCommit(for: root.branch)
            switch change {
            case .catchUp:
                let main = "main-for-\(new)"
                await workspace.advanceMain(to: main, mergedTip: new, branch: root.branch)
                try await baseline(main)
            case .personResolvingCatchUpConflict:
                let main = "main-for-\(new)"
                await workspace.advanceMain(to: main, mergedTip: new, branch: root.branch)
                try await baseline(main)
                try await ledger.append([LedgerEvent(node: root.id, by: .reconciler, kind:
                    .requirementCatchUpConflicted(branch: root.branch, main: main, files: ["Sources/Checkout.swift"], tickets: [root.ticket]))])
                try await workspace.move(root.branch, to: new, alsoContaining: [main])
            case .personCommit:
                try await workspace.move(root.branch, to: new)
            case .laterLeafLanding:
                try await workspace.move(root.branch, to: new)
                try await ledger.append([LedgerEvent(node: root.id + "-leaf", by: .reconciler, kind: .landed(commit: new))])
            }
            return new
        }

        func round(using other: Reconciler? = nil) async throws {
            let report = await (other ?? reconciler).runRound(waitForAgents: true)
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
        }

        func drain(using other: Reconciler? = nil) async throws {
            let reconciler = other ?? self.reconciler
            try await withHangGuard("GH-112 reaching an idle round") {
                while true {
                    try Task.checkCancellation()
                    let report = await reconciler.runRound(waitForAgents: true)
                    try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                    if report.isIdle { return }
                }
            }
        }

        func results(for root: Root, in source: Ledger? = nil) async -> [Evidence] {
            await (source ?? ledger).records(for: root.id).compactMap {
                if case .requirementVerificationFinished(let evidence) = $0.event.kind { return evidence }
                return nil
            }
        }
    }

    actor Branches: Workspace, RequirementBranchRepository {
        nonisolated let defaultBranch = "main"
        nonisolated let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        private var refs = ["main": "main-base", "origin/main": "main-base"]
        private var parents: [String: [String]] = ["main-base": []]
        private var snapshots: [URL: String] = [:]
        private var nextMerge: [String: String] = [:]
        private var counter = 0

        nonisolated func requirementBranch(for ticket: String) -> String { "agentos/\(ticket)" }
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: "unused/\(id)") }
        nonisolated var testArea: String { "Tests/" }
        nonisolated var agentContext: String { "" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated func existingComponents() -> [String] { [] }
        func add(_ requirement: Root, commit: String) {
            refs[requirement.branch] = commit
            parents[commit] = ["main-base"]
        }
        func nextCommit(for branch: String) -> String { counter += 1; return "new-\(branch.replacingOccurrences(of: "/", with: "-"))-\(counter)" }
        func tip(of branch: String) -> String? { refs[branch] }
        func advanceMain(to commit: String, mergedTip: String, branch: String) {
            parents[commit] = [refs["main"] ?? "main-base"]
            refs["main"] = commit
            refs["origin/main"] = commit
            nextMerge[branch] = mergedTip
        }
        func move(_ branch: String, to commit: String, alsoContaining other: [String] = []) throws {
            parents[commit] = [try #require(refs[branch])] + other
            refs[branch] = commit
        }
        func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
            let ancestor = refs[ancestor] ?? ancestor
            var pending = [refs[descendant] ?? descendant]
            var seen = Set<String>()
            while let next = pending.popLast() {
                if next == ancestor { return true }
                if seen.insert(next).inserted { pending += parents[next] ?? [] }
            }
            return false
        }
        func mergeMain(_ main: String, into branch: String) throws -> RebaseResult {
            let commit = try #require(nextMerge[branch], "The test must explicitly configure a catch-up commit")
            try move(branch, to: commit, alsoContaining: [main])
            return .clean
        }
        func changedFiles(in commit: String) -> [String] { ["Sources/Checkout.swift"] }
        func prepare() async throws {}
        func prepareRequirementBranch(for requirement: NodeIdentity, leaves: [NodeID]) async throws -> String? { nil }
        func requirementIsMerged(_ requirement: NodeIdentity) async throws -> Bool { false }
        func requirementWorktree(for requirement: NodeIdentity) async throws -> URL {
            let commit = try #require(refs[requirementBranch(for: requirement.ticketKey)])
            let directory = root.appending(path: "memory-checkouts/\(UUID().uuidString)")
            snapshots[directory] = commit
            return directory
        }
        func head(of directory: URL) throws -> String { try #require(snapshots[directory], "Unknown verification checkout") }
        func prepareBuild(in directory: URL) async throws {}
        func removeSnapshot(_ directory: URL) async { snapshots[directory] = nil }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        func removeWorktree(for id: NodeID) async throws {}
        func abortRebase(_ directory: URL) async throws {}
        func createWorktree(for id: NodeID) async throws -> URL { throw AgentFailure("Final verification must not create leaf work") }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Final verification must not write implementation")
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { throw AgentFailure("No leaf rework is expected") }
        func resetForRework(_ directory: URL) async throws { throw AgentFailure("No leaf rework is expected") }
        func landOnMain(_ id: NodeID) async throws -> String { throw AgentFailure("Final verification must not merge main") }
    }

    actor Checks: CheckRunner {
        struct Call: Sendable { let commit: String; let suite: String? }
        let workspace: Branches
        let trace: Trace
        nonisolated let started = TestGate()
        nonisolated let release = TestGate()
        private var passed = true
        private var summary = "Full checks passed"
        private var active = 0
        private(set) var maximumActive = 0
        private(set) var calls: [Call] = []
        init(workspace: Branches, trace: Trace) { self.workspace = workspace; self.trace = trace }
        func setResult(passed: Bool, summary: String? = nil) {
            self.passed = passed
            self.summary = summary ?? (passed ? "Full checks passed" : "Checkout integration failed")
        }
        func runChecks(in directory: URL, only suite: String?) async -> CheckOutput {
            do {
                let commit = try await workspace.head(of: directory)
                let passed = passed
                let summary = summary
                calls.append(Call(commit: commit, suite: suite))
                active += 1
                maximumActive = max(maximumActive, active)
                defer { active -= 1 }
                await trace.add(.checkStarted(commit))
                started.open()
                try await release.wait()
                await trace.add(.checkFinished(commit, passed))
                return CheckOutput(passed: passed, summary: summary, log: "\(summary)\nVerified commit \(commit)\n")
            } catch {
                Issue.record("Acceptance checker could not check its pinned checkout: \(error)")
                return CheckOutput(passed: false, summary: "\(error)", log: "\(error)")
            }
        }
    }

    final class Artifacts: ArtifactStore, Sendable {
        private let files = Mutex<[String: Data]>([:])
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            let path = "memory/\(name)"
            files.withLock { $0[path] = contents }
            return StoredArtifact(path: path, sha256: Hashing.sha256(contents))
        }
        func contents(of path: String) -> Data? { files.withLock { $0[path] } }
    }
}
