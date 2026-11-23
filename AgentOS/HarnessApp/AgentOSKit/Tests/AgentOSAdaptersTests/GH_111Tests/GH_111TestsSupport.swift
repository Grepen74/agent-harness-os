import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_111Tests {
    static let repository = "acceptance/durable-status"
    static let sha = String(repeating: "a", count: 40)
    static let oldSHA = String(repeating: "b", count: 40)
    static let nextSHA = String(repeating: "c", count: 40)
    static let postError = "GitHub status POST failed: HTTP 503 Service Unavailable"

    enum ResultKind: Sendable { case absent, passed, failed }
    struct StatusPostFailure: LocalizedError, CustomStringConvertible {
        var description: String { GH_111Tests.postError }
        var errorDescription: String? { description }
    }
    struct StatusRecord: Hashable, Sendable {
        let commit: String
        let state: RequirementVerificationStatus
    }
    struct Post: Sendable {
        let method: String
        let path: String
        let context: String
        let state: String
        let description: String
    }

    static func expect(_ post: Post, commit: String, state: RequirementVerificationStatus, description: String) {
        #expect(post.method == "POST")
        #expect(post.path == "repos/\(Self.repository)/statuses/\(commit)")
        #expect(post.context == "agentos/verified")
        #expect(post.state == state.rawValue)
        #expect(post.description == description)
    }

    static func policy(enabled: Bool) -> EffectivePolicy {
        var settings = HarnessSettings()
        settings.pullRequests = enabled
        return EffectivePolicy.resolve(harness: settings, repo: nil, defaultBranch: "main")
    }

    static func evidence(
        _ spec: NodeSpec, commit: String, passed: Bool, summary: String = "All acceptance checks passed",
        check: String = "final requirement verification"
    ) -> Evidence {
        Evidence(check: check, passed: passed, summary: summary, specHash: spec.specHash,
                 builtBy: "implement-GH-111", checkedBy: "verify-\(commit)",
                 artifactPath: "in-memory/\(commit).log", artifactSHA256: Hashing.sha256(Data(summary.utf8)),
                 commit: commit)
    }

    static func fixture(pushed: Bool = false, enabled: Bool = true) async throws -> Fixture {
        let ledger = try Ledger()
        let spec = NodeSpec(id: "wn-GH-111", parent: nil, kind: .leaf,
                            title: "Verified checkout", intent: "Reject invalid orders",
                            acceptanceCriteria: ["An order has a receipt"], touches: ["Checkout"])
        let trace = Trace()
        let fixture = Fixture(ledger: ledger, spec: spec, enabled: enabled, trace: trace,
                              github: GitHub(trace: trace), git: Git(trace: trace),
                              tracker: Tracker(), workspace: RoundWorkspace(), checks: Checks(), agents: Agents())
        try await fixture.append(.nodeCreated(spec: spec, ticket: "GH-111"))
        try await fixture.append(.phaseChanged(to: .proven))
        try await fixture.append(.landed(commit: Self.sha))
        try await fixture.append(.requirementBranchCreated(branch: fixture.branch, from: Self.oldSHA))
        try await fixture.append(.requirementBranchObserved(
            branch: fixture.branch, tip: Self.sha, main: Self.oldSHA, containedInMain: false))
        try await fixture.append(.requirementPullRequestOpened(
            number: 411, url: "https://github.com/\(Self.repository)/pull/411"))
        if pushed {
            try await fixture.append(.requirementPushed(branch: fixture.branch, commit: Self.sha))
            try await fixture.append(.requirementPublicationFinished(commit: Self.sha))
        } else {
            try await fixture.append(.requirementPublicationFinished(commit: Self.oldSHA))
        }
        return fixture
    }

    static func replay(_ ledger: Ledger) async throws -> Ledger {
        let json = try JSONEncoder().encode(await ledger.allRecords())
        let records = try JSONDecoder().decode([RecordedEvent].self, from: json)
        let store = InMemoryLedgerStore()
        store.append(records)
        return try Ledger(store: store)
    }

    static func round(_ reconciler: Reconciler) async throws {
        try await withHangGuard("GH-111 completing a reconciler round") {
            let report = await reconciler.runRound(waitForAgents: true)
            #expect(report.safeStop == nil, "\(report.safeStop ?? "")")
        }
    }

    struct Fixture: Sendable {
        let ledger: Ledger
        let spec: NodeSpec
        let enabled: Bool
        let trace: Trace
        let github: GitHub
        let git: Git
        let tracker: Tracker
        let workspace: RoundWorkspace
        let checks: Checks
        let agents: Agents
        var branch: String { "agentos/GH-111" }

        func append(_ kind: EventKind, by participant: Participant = .reconciler) async throws {
            try await ledger.append([LedgerEvent(node: spec.id, by: participant, kind: kind)])
        }

        func recordResult(commit: String, passed: Bool, summary: String = "All acceptance checks passed") async throws {
            try await append(.requirementVerificationStarted)
            let evidence = GH_111Tests.evidence(spec, commit: commit, passed: passed, summary: summary)
            try await append(.requirementVerificationFinished(evidence),
                             by: .agent(run: evidence.checkedBy, role: .verifier))
        }

        func request() async -> RequirementPublicationRequest {
            RequirementPublicationRequest(requirement: spec.id, branch: branch, commit: GH_111Tests.sha,
                verification: await ledger.workingState().nodes[spec.id]?.requirementVerification.map { [$0] },
                proofs: [])
        }

        func publisher(ledger replacement: Ledger? = nil, enabled override: Bool? = nil) -> PullRequestPublicationCoordinator {
            PullRequestPublicationCoordinator(
                ledger: replacement ?? ledger, tracker: tracker, repository: GH_111Tests.repository,
                policy: GH_111Tests.policy(enabled: override ?? enabled), transport: github,
                git: { [git] arguments in try await git.run(arguments) })
        }

        func reconciler(ledger replacement: Ledger? = nil, publisher: any RequirementPublisher) -> Reconciler {
            Reconciler(ledger: replacement ?? ledger, tracker: tracker, external: External(),
                       workspace: workspace, artifacts: Artifacts(), checks: checks,
                       team: AgentTeam(name: "GH-111 no rework", decomposer: agents, testAuthor: agents, implementer: agents),
                       policy: GH_111Tests.policy(enabled: enabled).policy, publisher: publisher)
        }

        func recordedStatuses(in replacement: Ledger? = nil) async throws -> [StatusRecord] {
            // Round-trip the persisted records, not merely an in-memory projection.
            let json = try JSONEncoder().encode(await (replacement ?? ledger).records(for: spec.id))
            let records = try JSONDecoder().decode([RecordedEvent].self, from: json)
            return records.compactMap {
                if case .requirementVerificationStatusPosted(let commit, let state) = $0.event.kind {
                    return StatusRecord(commit: commit, state: state)
                }
                return nil
            }
        }

        func expectStatusFailure(in ledger: Ledger, status: String) async throws {
            let state = await ledger.workingState()
            let root = try #require(state.nodes[spec.id])
            #expect(state.attentionList.contains {
                $0.node.id == spec.id && !$0.reason.isEmpty && $0.reason.localizedCaseInsensitiveContains("status")
            },
                    "Needs attention must retain the status error until a post succeeds.")
            #expect(state.status(of: root) == status)
            #expect(root.publicationFailure == nil)
            #expect(root.reworks == 0)
            #expect(root.failedAttempts == 0)
            #expect(await agents.calls.isEmpty)
            #expect(await checks.calls == 0)
        }
    }

    actor Trace {
        private(set) var operations: [String] = []
        func record(_ operation: String) { operations.append(operation) }
    }

    actor Git {
        let trace: Trace
        private var tip = GH_111Tests.sha
        private var rejectsPush = false
        private(set) var pushes = 0
        init(trace: Trace) { self.trace = trace }
        func setTip(_ value: String) { tip = value }
        func rejectPush() { rejectsPush = true }
        func run(_ arguments: [String]) async throws -> String {
            switch arguments.first {
            case "rev-parse": return tip
            case "push":
                pushes += 1
                if rejectsPush { throw AgentFailure("origin rejected requirement push") }
                await trace.record("push")
                return tip
            case "remote": return "https://github.com/\(GH_111Tests.repository).git"
            default: throw AgentFailure("Unexpected git operation in GH-111: \(arguments)")
            }
        }
    }

    actor GitHub: GitHubTransport {
        let trace: Trace
        private var failuresRemaining = 0
        private(set) var posts: [Post] = []
        private(set) var successfulPosts = 0
        private(set) var pullRequestUpdates = 0
        init(trace: Trace) { self.trace = trace }
        func failStatusPosts(_ count: Int) { failuresRemaining = count }
        func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
            let statuses = "repos/\(GH_111Tests.repository)/statuses/"
            if method == "POST", path.hasPrefix(statuses) {
                let payload = try #require(body)
                let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                let post = Post(method: method, path: path,
                                context: try #require(object["context"] as? String),
                                state: try #require(object["state"] as? String),
                                description: try #require(object["description"] as? String))
                posts.append(post)
                let commit = String(path.dropFirst(statuses.count))
                await trace.record("status:\(commit):\(post.state)")
                if failuresRemaining > 0 {
                    failuresRemaining -= 1
                    throw StatusPostFailure()
                }
                successfulPosts += 1
                return try JSONSerialization.data(withJSONObject: [
                    "id": successfulPosts, "state": post.state, "context": post.context,
                    "description": post.description, "sha": commit, "target_url": NSNull(),
                    "url": "https://api.github.com/\(path)/\(successfulPosts)",
                ])
            }
            let pr = "repos/\(GH_111Tests.repository)/pulls/411"
            if path == pr, method == "GET" || method == "PATCH" {
                if method == "PATCH" { pullRequestUpdates += 1 }
                return try JSONSerialization.data(withJSONObject: [
                    "number": 411, "html_url": "https://github.com/\(GH_111Tests.repository)/pull/411",
                    "state": "open", "merged_at": NSNull(),
                ])
            }
            throw AgentFailure("Unexpected GitHub request in GH-111: \(method) \(path)")
        }
    }

    actor Tracker: TrackerAdapter {
        private(set) var statuses: [String] = []
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? {
            Ticket(key: key, title: "Verified checkout", description: "Reject invalid orders",
                   acceptanceCriteria: ["An order has a receipt"], createdBy: .human("Reviewer"))
        }
        func contextTickets() async -> [Ticket] { [] }
        func consume(_ signal: Signal, reply: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by who: Participant) async throws -> String {
            throw AgentFailure("Status publication must not create child tickets")
        }
        func comment(on key: String, _ text: String) async {}
        func setStatus(of key: String, to status: String) async { statuses.append(status) }
    }

    actor Checks: CheckRunner {
        private(set) var calls = 0
        func runChecks(in directory: URL, only suite: String?) async -> CheckOutput {
            calls += 1
            return CheckOutput(passed: true, summary: "Unexpected repeated final verification", log: "")
        }
    }

    actor Agents: Decomposer, TestAuthor, Implementer {
        private(set) var calls: [AgentRole] = []
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            calls.append(.decomposer)
            throw AgentFailure("Commit status posting must not start decomposition")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            calls.append(.testAuthor)
            throw AgentFailure("Commit status posting must not restart test authoring")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            calls.append(.implementer)
            throw AgentFailure("Commit status posting must not start agent rework")
        }
    }

    private struct External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
    private struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    actor RoundWorkspace: Workspace {
        nonisolated let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        private(set) var mutations: [String] = []
        nonisolated var testArea: String { "Tests/" }
        nonisolated var agentContext: String { "" }
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated func existingComponents() -> [String] { [] }
        func prepare() async throws {}
        func requirementWorktree(for requirement: NodeIdentity) async throws -> URL {
            mutations.append("final verification checkout")
            return root
        }
        func requirementIsMerged(_ requirement: NodeIdentity) async throws -> Bool { false }
        func head(of directory: URL) async throws -> String { GH_111Tests.sha }
        func prepareBuild(in directory: URL) async throws { mutations.append("prepare build") }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        func removeWorktree(for id: NodeID) async throws { mutations.append("remove worktree") }
        func abortRebase(_ directory: URL) async throws { mutations.append("abort rebase") }
        func createWorktree(for id: NodeID) async throws -> URL {
            mutations.append("create worktree")
            throw AgentFailure("Commit statuses must not create a leaf worktree")
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            mutations.append("commit")
            throw AgentFailure("Commit statuses must not commit implementation")
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            mutations.append("rebase")
            throw AgentFailure("Commit statuses must not rebase proven leaves")
        }
        func resetForRework(_ directory: URL) async throws {
            mutations.append("reset")
            throw AgentFailure("Commit statuses must not reset proven leaves")
        }
        func landOnMain(_ id: NodeID) async throws -> String {
            mutations.append("land")
            throw AgentFailure("Commit statuses must not land work")
        }
    }
}
