import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

extension GH_92Tests {
    private enum GH92Unexpected: Error {
        case request(String)
    }

    struct GH92Fixture {
        static let repo = "owner/project"
        static let ticket = "GH-92"
        static let nodeID = "wn-GH-92"
        static let prNumber = 192
        static let prURL = "https://github.com/owner/project/pull/192"

        let ledger: Ledger
        let github: GH92GitHub
        let tracker: GitHubIssuesTracker
        let service: GH92PullRequests
        let workspace: GH92Workspace
        let agents: GH92Agents
        let checks: GH92Checks

        static func make(
            hasProject: Bool = false, composite: Bool = false, alreadyPublished: Bool = true
        ) async throws -> Self {
            let ledger = try Ledger()
            let spec = NodeSpec(
                id: nodeID, kind: composite ? .composite : .leaf, title: "Deliver greeting",
                intent: "Show a friendly greeting", acceptanceCriteria: ["A greeting is visible"]
            )
            try await ledger.append([
                LedgerEvent(node: nodeID, by: .human("reviewer"), kind: .nodeCreated(spec: spec, ticket: ticket)),
                LedgerEvent(node: nodeID, by: .human("reviewer"), kind: .gateOpened(.breakdown)),
                LedgerEvent(node: nodeID, by: .human("reviewer"), kind: .gateOpened(.build)),
            ])
            if composite {
                let child = NodeSpec(
                    id: "wn-GH-93", parent: nodeID, kind: .leaf, title: "Show greeting",
                    intent: "Part of Deliver greeting", acceptanceCriteria: ["A greeting is visible"]
                )
                try await ledger.append([
                    LedgerEvent(node: child.id, by: .reconciler, kind: .nodeCreated(spec: child, ticket: "GH-93")),
                    LedgerEvent(node: child.id, by: .reconciler, kind: .landed(commit: "greeting-tip")),
                    LedgerEvent(node: child.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
                ])
            }
            if !composite {
                try await ledger.append([
                    LedgerEvent(node: nodeID, by: .reconciler, kind: .landed(commit: "greeting-tip"))
                ])
            }
            try await ledger.append([
                LedgerEvent(node: nodeID, by: .reconciler, kind: .phaseChanged(to: .proven))
            ])
            if alreadyPublished {
                try await ledger.append([
                    LedgerEvent(
                        node: nodeID, by: .reconciler,
                        kind: .requirementPullRequestOpened(number: prNumber, url: prURL))
                ])
            }
            let github = GH92GitHub()
            let tracker = GitHubIssuesTracker(
                repo: repo, transport: github,
                project: hasProject
                    ? .init(
                        owner: "owner", number: 7,
                        statusMap: [
                            "In review": "Awaiting approval", "Done": "Completed",
                            "Needs input": "Needs input",
                        ]) : nil, listInterval: .zero
            )
            return Self(
                ledger: ledger, github: github, tracker: tracker,
                service: GH92PullRequests(alreadyPublished: alreadyPublished),
                workspace: GH92Workspace(), agents: GH92Agents(), checks: GH92Checks()
            )
        }

        func reconciler(using ledger: Ledger? = nil) -> Reconciler {
            Reconciler(
                ledger: ledger ?? self.ledger, tracker: tracker, external: GH92External(),
                workspace: workspace, artifacts: GH92Artifacts(), checks: checks,
                team: AgentTeam(
                    name: "No build work expected", decomposer: agents, testAuthor: agents, implementer: agents),
                pullRequests: service
            )
        }

        func settle(_ reconciler: Reconciler? = nil) async throws {
            let reconciler = reconciler ?? self.reconciler()
            while true {
                try Task.checkCancellation()
                let report = await reconciler.runRound(waitForAgents: true)
                try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                if report.isIdle { return }
            }
        }

        func reloadedLedger() async throws -> Ledger {
            let data = try JSONEncoder().encode(await ledger.allRecords())
            let store = InMemoryLedgerStore()
            store.append(try JSONDecoder().decode([RecordedEvent].self, from: data))
            return try Ledger(store: store)
        }
    }

    actor GH92PullRequests: RequirementPullRequestService {
        enum Write: Equatable {
            case push(String)
            case open(String)
            case reopen(Int)
        }
        private var state: RequirementPullRequest.State = .open
        private var alreadyPublished: Bool
        private(set) var writes: [Write] = []

        init(alreadyPublished: Bool) { self.alreadyPublished = alreadyPublished }
        func observe(_ state: RequirementPullRequest.State) { self.state = state }
        func pullRequest(number: Int) async throws -> RequirementPullRequest {
            guard number == GH92Fixture.prNumber else { throw GH92Unexpected.request("Unknown PR \(number)") }
            return snapshot()
        }
        func push(branch: String) async throws -> String {
            writes.append(.push(branch))
            return "greeting-tip"
        }
        func open(branch: String, title: String, body: String) async throws -> RequirementPullRequest {
            writes.append(.open(branch))
            guard !alreadyPublished else { throw GH92Unexpected.request("An existing PR must not be replaced") }
            alreadyPublished = true
            return snapshot()
        }
        func reopen(number: Int) async throws -> RequirementPullRequest {
            writes.append(.reopen(number))
            guard number == GH92Fixture.prNumber else { throw GH92Unexpected.request("Unknown PR \(number)") }
            state = .open
            return snapshot()
        }
        private func snapshot() -> RequirementPullRequest {
            RequirementPullRequest(number: GH92Fixture.prNumber, url: GH92Fixture.prURL, state: state)
        }
    }

    actor GH92GitHub: GitHubTransport {
        private(set) var labels: Set<String> = ["bug", "agentos: Ready"]
        private(set) var comments: [String] = []
        var boardStatus: String? { boardStatuses[92] }
        private(set) var boardWrites: [String] = []
        private var boardStatuses = [92: "Queue", 93: "Queue"]
        private var issueClosed = false
        private var revision = 0
        private var signals: [HarnessCommand] = []

        func setIssueClosed(_ value: Bool) {
            issueClosed = value
            revision += 1
        }
        func statusLabels() -> Set<String> { Set(labels.filter { $0.hasPrefix("agentos: ") }) }
        func addHumanSignal(_ command: HarnessCommand) {
            labels.insert(command.label)
            signals.append(command)
            revision += 1
        }

        func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
            let sent =
                try body.map {
                    try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
                } ?? [:]
            let route = path.split(separator: "?").first.map(String.init) ?? path
            let issuePath = "repos/\(GH92Fixture.repo)/issues"
            let itemPath = "\(issuePath)/92"
            let value: Any
            switch (method, route) {
            case ("GET", issuePath):
                value = issueClosed ? [] : [issue()]
            case ("GET", itemPath):
                value = issue()
            case ("GET", "\(issuePath)/93"):
                var child = issue()
                child["id"] = 1093
                child["number"] = 93
                child["labels"] = []
                value = child
            case ("GET", "\(itemPath)/comments"):
                value = comments.enumerated().map { index, text in
                    [
                        "id": 500 + index, "body": text,
                        "user": ["login": "harness", "type": "User"], "created_at": "2026-11-16T19:00:00Z",
                    ] as [String: Any]
                }
            case ("GET", "\(issuePath)/93/comments"), ("GET", "\(issuePath)/93/events"):
                value = []
            case ("GET", "\(itemPath)/events"):
                value = signals.map {
                    [
                        "event": "labeled", "actor": ["login": "reviewer", "type": "User"],
                        "label": ["name": $0.label],
                    ]
                }
            case ("POST", "repos/\(GH92Fixture.repo)/labels"):
                value = [:] as [String: String]
            case ("POST", "\(itemPath)/labels"):
                let names = try #require(sent["labels"] as? [String])
                labels.formUnion(names)
                revision += 1
                value = labels.map { ["name": $0] }
            case ("POST", "\(issuePath)/93/labels"):
                value = []
            case ("POST", "\(itemPath)/comments"):
                comments.append(try #require(sent["body"] as? String))
                revision += 1
                value = [:] as [String: String]
            case ("POST", "\(issuePath)/93/comments"):
                value = [:] as [String: String]
            case ("DELETE", _) where route.hasPrefix("\(itemPath)/labels/"):
                let encoded = String(route.dropFirst("\(itemPath)/labels/".count))
                labels.remove(encoded.removingPercentEncoding ?? encoded)
                revision += 1
                value = [:] as [String: String]
            case ("POST", "graphql"):
                value = try graphql(sent)
            default:
                throw GH92Unexpected.request("\(method) \(path)")
            }
            return try JSONSerialization.data(withJSONObject: value)
        }

        private func issue() -> [String: Any] {
            [
                "id": 1092, "number": 92, "title": "Deliver greeting",
                "body": "Show a friendly greeting\n\n## Acceptance criteria\n- [ ] A greeting is visible",
                "state": issueClosed ? "closed" : "open",
                "labels": labels.sorted().map { ["name": $0] },
                "user": ["login": "reviewer", "type": "User"], "updated_at": "revision-\(revision)",
            ]
        }

        private func graphql(_ sent: [String: Any]) throws -> [String: Any] {
            let query = try #require(sent["query"] as? String)
            let variables = try #require(sent["variables"] as? [String: Any])
            if query.contains("repositoryOwner") {
                let options = ["Queue", "Awaiting approval", "Completed", "In review", "Done", "Needs input"].map {
                    ["id": "option-\($0)", "name": $0]
                }
                return [
                    "data": [
                        "repositoryOwner": [
                            "projectV2": [
                                "id": "project-7", "title": "Delivery",
                                "field": ["id": "status-field", "options": options],
                            ]
                        ]
                    ]
                ]
            }
            if query.contains("updateProjectV2ItemFieldValue") {
                let option = try #require(variables["option"] as? String)
                let item = try #require(variables["item"] as? String)
                let number = try #require(Int(item.dropFirst("card-".count)))
                let status = String(option.dropFirst("option-".count))
                boardStatuses[number] = status
                boardWrites.append("\(number): \(status)")
                return ["data": ["updateProjectV2ItemFieldValue": ["projectV2Item": ["id": item]]]]
            }
            if query.contains("projectItems") {
                let number = try #require(variables["number"] as? Int)
                var card: [String: Any] = ["id": "card-\(number)", "project": ["id": "project-7"]]
                if let status = boardStatuses[number] { card["fieldValueByName"] = ["name": status] }
                return [
                    "data": [
                        "repository": [
                            "issue": [
                                "id": "issue-\(number)", "projectItems": ["nodes": [card]],
                            ]
                        ]
                    ]
                ]
            }
            throw GH92Unexpected.request("Unexpected GraphQL operation")
        }
    }

    actor GH92Workspace: Workspace {
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
            worktree(for: requirement.nodeID)
        }
        func requirementIsMerged(_ requirement: NodeIdentity) async throws -> Bool { false }
        func createWorktree(for id: NodeID) async throws -> URL {
            mutations.append("create \(id)")
            return worktree(for: id)
        }
        func removeWorktree(for id: NodeID) async throws { mutations.append("remove \(id)") }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            mutations.append("commit")
            return "unexpected-commit"
        }
        func head(of directory: URL) async throws -> String { "greeting-tip" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            mutations.append("rebase")
            return .clean
        }
        func abortRebase(_ directory: URL) async throws { mutations.append("abort") }
        func resetForRework(_ directory: URL) async throws { mutations.append("reset") }
        func landOnMain(_ id: NodeID) async throws -> String {
            mutations.append("land \(id)")
            return "unexpected-landing"
        }
        func prepareBuild(in directory: URL) async throws { mutations.append("prepare build") }
    }

    actor GH92Agents: Decomposer, TestAuthor, Implementer {
        private(set) var calls: [String] = []
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            calls.append("breakdown")
            throw AgentFailure("PR lifecycle must not start an agent")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            calls.append("tests")
            throw AgentFailure("PR lifecycle must not start an agent")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            calls.append("implementation")
            throw AgentFailure("PR lifecycle must not start an agent")
        }
    }

    actor GH92Checks: CheckRunner {
        private(set) var calls = 0
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            calls += 1
            return CheckOutput(passed: true, summary: "Already verified before publication", log: "")
        }
    }

    private struct GH92External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct GH92Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }
}
