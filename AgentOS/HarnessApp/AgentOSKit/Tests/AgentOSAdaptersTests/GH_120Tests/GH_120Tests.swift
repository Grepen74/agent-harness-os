// Expected API: GitHubIssuesTracker's existing GitHubTransport-backed ticket/signal API,
// Reconciler.runRound(waitForAgents:), Ledger.workingState(), and WorkingState.attentionList.
// Confirmed descriptions must reach ticket/context snapshots and BreakdownRequest.spec;
// a successful replan must also replace NodeState.spec. No new public symbols are required.
// The held-edit prerequisite is supplied by the sibling work, not implemented on this base.
// The transport exposes raw body changes, update timestamps and edit history without
// requiring a particular GraphQL query or a particular edit-detection strategy.
// Criterion 3 (real-repo-mode.md explaining both confirmation routes) is source-only:
// the reviewer checks the documentation diff, not a test.

import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

@Suite struct GH_120Tests {
    private static let repository = "acceptance/held-description"
    private static let ticketKey = "GH-120"
    private static let approved = "Show the approved greeting."
    private static let held = "Show the proposed greeting instead."
    private static let nextUntrustedEdit = "Replace the greeting with another unconfirmed proposal."

    enum ConfirmationEdit: String, Sendable, CaseIterable {
        case whitespaceOnly, substantive

        var description: String {
            switch self {
            case .whitespaceOnly: GH_120Tests.held
            case .substantive: "Show the maintainer's revised greeting."
            }
        }

        var body: String {
            let body = GH_120Tests.issueBody(description)
            return self == .whitespaceOnly ? body + "\n" : body
        }
    }

    @Test(arguments: ["write", "maintain", "admin"], ConfirmationEdit.allCases)
    func aWriteAuthorizedDescriptionEditConfirmsTheHeldTextAndClearsItsAttentionEntry(
        permission: String, edit: ConfirmationEdit
    ) async throws {
        let fixture = try await Self.fixture(permission: permission)
        try await fixture.holdDescriptionEdit()

        await fixture.github.editDescription(edit.body, by: "writer")
        try await fixture.round()

        #expect(await fixture.descriptionAttention().isEmpty,
                "Editing the held description with write access must remove its Needs attention entry.")
        try await fixture.expectDescription(edit.description)
        try await fixture.expectFreshPreviewReads(edit.description)
        try await fixture.expectLaterUntrustedEditKeeps(edit.description)
    }

    @Test(arguments: ["write", "maintain", "admin"])
    func aWriteAuthorizedReplanUsesTheHeldCurrentDescriptionAndClearsItsAttentionEntry(
        permission: String
    ) async throws {
        let fixture = try await Self.fixture(permission: permission)
        try await fixture.holdDescriptionEdit()

        // No body edit or answer comment: the label itself is the confirmation.
        await fixture.github.addSignal(.replan, by: "writer")
        try await fixture.round()

        let state = await fixture.ledger.workingState()
        let node = try #require(state.node(forTicket: Self.ticketKey))
        #expect(node.spec.intent == Self.held,
                "Replanning must use the current GitHub description, not the previously accepted snapshot.")
        #expect(node.gates.isEmpty, "Confirmation by replan does not approve the new plan.")
        #expect(await fixture.descriptionAttention().isEmpty,
                "Replanning from held text must remove its Needs attention entry.")
        #expect(await fixture.tracker.ticket(Self.ticketKey)?.comments.contains {
            $0.author == .reconciler && $0.text.contains("✅ harness:replan")
        } == true)
        try await fixture.expectDescription(Self.held)
        try await fixture.expectFreshPreviewReads(Self.held)
        try await fixture.expectLaterUntrustedEditKeeps(Self.held)
    }

    @Test func theFixtureReadsAnIssueAndObservesAnExistingDecomposerRun() async throws {
        // Exercise the transport and agent spy against behaviour that already exists.
        let fixture = try await Self.fixture(permission: "write")
        try await fixture.expectDescription(Self.approved)
        #expect(await fixture.descriptionAttention().isEmpty)
        try await fixture.expectFreshPreviewReads(Self.approved)
    }

    @Test func theTransportExposesWhitespaceEditsThroughBodyTimestampsAndHistory() async throws {
        let github = GitHub(permission: "write")
        let tracker = GitHubIssuesTracker(repo: Self.repository, transport: github, listInterval: .zero)
        let beforeTicket = try #require(await tracker.ticket(Self.ticketKey))
        let path = "repos/\(Self.repository)/issues/120"
        let beforeData = try await github.request("GET", path, body: nil)
        let before = try #require(JSONSerialization.jsonObject(with: beforeData) as? [String: Any])
        let beforeBody = try #require(before["body"] as? String)
        await github.editDescription(beforeBody + "\n", by: "writer")
        let afterData = try await github.request("GET", path, body: nil)
        let after = try #require(JSONSerialization.jsonObject(with: afterData) as? [String: Any])
        #expect(after["body"] as? String == beforeBody + "\n")
        #expect(after["updated_at"] as? String != before["updated_at"] as? String)
        let afterTicket = try #require(await tracker.ticket(Self.ticketKey))
        #expect(afterTicket.description == beforeTicket.description,
                "The whitespace case changes the raw body even when the existing parser normalizes it away.")

        let query = """
        query { repository(owner: "acceptance", name: "held-description") {
          issue(number: 120) { body userContentEdits(first: 1) { nodes { editedAt editor { login } } } }
        } }
        """
        let graphData = try await github.request(
            "POST", "graphql", body: JSONSerialization.data(withJSONObject: ["query": query])
        )
        let graph = try #require(JSONSerialization.jsonObject(with: graphData) as? [String: Any])
        let data = try #require(graph["data"] as? [String: Any])
        let repository = try #require(data["repository"] as? [String: Any])
        let issue = try #require(repository["issue"] as? [String: Any])
        #expect(issue["body"] as? String == after["body"] as? String)
        let edits = try #require(issue["userContentEdits"] as? [String: Any])
        let nodes = try #require(edits["nodes"] as? [[String: Any]])
        let latest = try #require(nodes.last)
        #expect((latest["editor"] as? [String: Any])?["login"] as? String == "writer")
        #expect(latest["editedAt"] as? String == after["updated_at"] as? String)

        // Label updates change updated_at but do not invent a description edit.
        await github.addSignal(.preview, by: "writer")
        let laterGraphData = try await github.request(
            "POST", "graphql", body: JSONSerialization.data(withJSONObject: ["query": query])
        )
        let laterGraph = try #require(JSONSerialization.jsonObject(with: laterGraphData) as? [String: Any])
        let laterData = try #require(laterGraph["data"] as? [String: Any])
        let laterRepository = try #require(laterData["repository"] as? [String: Any])
        let laterIssue = try #require(laterRepository["issue"] as? [String: Any])
        #expect(laterIssue["lastEditedAt"] as? String == latest["editedAt"] as? String)
        #expect(laterIssue["updatedAt"] as? String != laterIssue["lastEditedAt"] as? String)
    }

    private static func issueBody(_ description: String) -> String {
        "\(description)\n\n## Acceptance criteria\n- [ ] The greeting is visible."
    }

    private static func fixture(permission: String) async throws -> Fixture {
        let github = GitHub(permission: permission)
        let tracker = GitHubIssuesTracker(repo: Self.repository, transport: github, listInterval: .zero)
        let ledger = try Ledger()
        let agents = Agents()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "unused-workspace-\(UUID().uuidString)")
        let reconciler = Reconciler(
            ledger: ledger, tracker: tracker, external: External(), workspace: WorkspaceStub(root: root),
            artifacts: Artifacts(), checks: Checks(),
            team: AgentTeam(name: "Held description observations",
                            decomposer: agents, testAuthor: agents, implementer: agents),
            policy: Policy(guesswork: .ask)
        )
        let fixture = Fixture(github: github, tracker: tracker, ledger: ledger,
                              agents: agents, reconciler: reconciler, baselineAttention: [])
        await github.addSignal(.breakdown, by: "writer")
        try await fixture.round()
        let state = await ledger.workingState()
        let node = try #require(state.node(forTicket: Self.ticketKey),
                                "The fixture must adopt its issue through normal signal intake.")
        try #require(node.spec.intent == Self.approved)
        try #require(await agents.requests.contains {
            $0.identity.ticketKey == Self.ticketKey && $0.spec.intent == Self.approved
        }, "The fixture's spy must observe the actual request sent to the decomposer.")
        let baselineAttention = Set(state.attentionList.filter {
            $0.node.ticket == Self.ticketKey
        }.map(\.reason))
        return Fixture(github: github, tracker: tracker, ledger: ledger, agents: agents,
                       reconciler: reconciler, baselineAttention: baselineAttention)
    }

    private struct Fixture: Sendable {
        let github: GitHub
        let tracker: GitHubIssuesTracker
        let ledger: Ledger
        let agents: Agents
        let reconciler: Reconciler
        let baselineAttention: Set<String>

        func round() async throws {
            let report = try await withHangGuard("GH-120 description reconciliation") {
                await reconciler.runRound(waitForAgents: true)
            }
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
            let problems = await tracker.takeProblems()
            try #require(problems.isEmpty, "Fixture transport errors: \(problems)")
        }

        func descriptionAttention() async -> [String] {
            let state = await ledger.workingState()
            // Exclude the fixture's existing clarification without prescribing held-edit wording or flags.
            return state.attentionList.filter {
                $0.node.ticket == GH_120Tests.ticketKey
                    && !baselineAttention.contains($0.reason)
            }.map(\.reason)
        }

        func holdDescriptionEdit() async throws {
            await github.editDescription(GH_120Tests.issueBody(GH_120Tests.held), by: "outsider")
            try await round()
            let ticket = try #require(await tracker.ticket(GH_120Tests.ticketKey))
            try #require(ticket.description == GH_120Tests.approved,
                    "Prerequisite: an outsider's post-approval edit must be held before it can be confirmed.")
            try #require(await !descriptionAttention().isEmpty,
                    "Prerequisite: the held edit must have a Needs attention entry before confirmation.")
        }

        func expectDescription(_ description: String) async throws {
            let ticket = try #require(await tracker.ticket(GH_120Tests.ticketKey))
            #expect(ticket.description == description)
            let tickets = await tracker.contextTickets()
            #expect(tickets.first { $0.key == GH_120Tests.ticketKey }?.description == description)
            let referring = Ticket(key: "GH-121", title: "Use the greeting",
                                   description: "See #120.", acceptanceCriteria: ["The greeting is reused."],
                                   createdBy: .human("writer"))
            let context = AgentContextBuilder.build(
                ticket: referring, tickets: tickets, repository: GH_120Tests.repository, designDocumentPaths: []
            )
            #expect(context.linkedIssues.first { $0.key == GH_120Tests.ticketKey }?.description == description,
                    "Subsequent agent context must not retain the old accepted description.")
            #expect(await tracker.ticket(GH_120Tests.ticketKey)?.description == description,
                    "Confirmation must survive repeated ticket reads.")
        }

        func expectFreshPreviewReads(_ description: String) async throws {
            let previousCount = await agents.requests.count
            await github.addSignal(.preview, by: "writer")
            try await round()
            let requests = await agents.requests
            let fresh = requests.dropFirst(previousCount)
            try #require(!fresh.isEmpty, "The preview must actually run the observing decomposer.")
            #expect(fresh.allSatisfy { $0.spec.intent == description },
                    "Every decomposer request after confirmation must read the current description.")
        }

        func expectLaterUntrustedEditKeeps(_ confirmed: String) async throws {
            await github.editDescription(GH_120Tests.issueBody(GH_120Tests.nextUntrustedEdit), by: "outsider")
            try await round()
            #expect(await tracker.ticket(GH_120Tests.ticketKey)?.description == confirmed,
                    "Confirmation must advance the accepted snapshot used for a later held edit.")
            #expect(await !descriptionAttention().isEmpty,
                    "A later outsider edit still needs confirmation; confirming once is not permanent trust.")
        }
    }

    private actor Agents: Decomposer, TestAuthor, Implementer {
        private(set) var requests: [BreakdownRequest] = []

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            requests.append(request)
            // Keep the adopted root idle before building, without imposing any scheduling order.
            return Breakdown(children: [], report: AgentReport(questions: ["Which greeting should be shown?"]))
        }

        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("The fixture waits for input; it must not start test authoring.")
        }

        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("The fixture has not approved building.")
        }
    }

    private actor GitHub: GitHubTransport {
        private var body = GH_120Tests.issueBody(GH_120Tests.approved)
        private var editor = "writer"
        private var revision = 0
        private var lastEditedAt = "2025-01-01T00:00:00Z"
        private var edits: [[String: Any]] = []
        private var labels: [String] = []
        private var comments: [[String: Any]] = []
        private var events: [[String: Any]] = []
        private let permissions: [String: String]

        init(permission: String) {
            permissions = ["writer": permission, "outsider": "read", "harness-login": "write"]
        }

        private var updatedAt: String {
            Date(timeIntervalSince1970: 1_735_689_600 + Double(revision)).ISO8601Format()
        }

        private static func user(_ login: String) -> [String: String] {
            ["login": login, "type": "User"]
        }

        private var issue: [String: Any] {
            [
                "id": 1120, "node_id": "I_120", "number": 120, "title": "Confirm the greeting",
                "body": body, "state": "open", "user": Self.user("writer"),
                "labels": labels.map { ["name": $0] }, "updated_at": updatedAt,
            ]
        }

        func editDescription(_ text: String, by login: String) {
            let previousBody = body
            body = text
            editor = login
            revision += 1
            lastEditedAt = updatedAt
            edits.append([
                "__typename": "UserContentEdit", "id": "edit-\(revision)",
                "editor": Self.user(login), "editedAt": lastEditedAt,
                "createdAt": lastEditedAt, "updatedAt": lastEditedAt,
                "diff": "-\(previousBody)\n+\(text)",
            ])
            events.append([
                "id": revision, "event": "edited", "actor": Self.user(login),
                "created_at": lastEditedAt, "body": ["from": previousBody],
            ])
        }

        func addSignal(_ command: HarnessCommand, by login: String) {
            addLabel(command.label, by: login)
        }

        private func addLabel(_ name: String, by login: String) {
            if !labels.contains(name) { labels.append(name) }
            events.append(["event": "labeled", "actor": Self.user(login), "label": ["name": name]])
            revision += 1
        }

        func request(_ method: String, _ path: String, body sentBody: Data?) async throws -> Data {
            let route = String(path.split(separator: "?")[0])
            let prefix = "repos/\(GH_120Tests.repository)"
            let issueRoute = "\(prefix)/issues/120"
            let sent: [String: Any]
            if let sentBody {
                sent = try #require(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
            } else {
                sent = [:]
            }
            let response: Any
            switch (method, route) {
            case ("GET", "user"):
                response = Self.user("harness-login")
            case ("GET", "\(prefix)/issues"):
                response = path.contains("page=2") ? [] : [issue]
            case ("GET", issueRoute):
                response = issue
            case ("GET", "\(issueRoute)/comments"):
                response = path.contains("page=2") ? [] : comments
            case ("GET", "\(issueRoute)/events"):
                response = path.contains("page=2") ? [] : events
            case ("GET", "\(issueRoute)/timeline"):
                response = path.contains("page=2") ? [] : events
            case ("POST", "\(prefix)/labels"):
                response = ["name": try #require(sent["name"] as? String)]
            case ("POST", "\(issueRoute)/labels"):
                for name in try #require(sent["labels"] as? [String]) {
                    addLabel(name, by: "harness-login")
                }
                response = labels.map { ["name": $0] }
            case ("POST", "\(issueRoute)/comments"):
                revision += 1
                let comment: [String: Any] = [
                    "id": 5000 + comments.count, "body": try #require(sent["body"] as? String),
                    "user": Self.user("harness-login"), "created_at": updatedAt,
                ]
                comments.append(comment)
                response = comment
            case ("POST", "graphql"):
                let graphIssue: [String: Any] = [
                    "__typename": "Issue",
                    "id": "I_120", "number": 120, "body": body, "title": "Confirm the greeting",
                    "editor": Self.user(editor), "author": Self.user("writer"),
                    "lastEditedAt": lastEditedAt, "updatedAt": updatedAt,
                    "userContentEdits": Self.connection(edits),
                ]
                response = ["data": [
                    "viewer": Self.user("harness-login"),
                    "node": graphIssue, "nodes": [graphIssue],
                    "repository": ["issue": graphIssue, "issues": Self.connection([graphIssue])],
                ]]
            default:
                if method == "GET", route.hasPrefix("\(prefix)/collaborators/"),
                   route.hasSuffix("/permission") {
                    let login = String(route.dropFirst("\(prefix)/collaborators/".count)
                        .dropLast("/permission".count)).removingPercentEncoding ?? ""
                    let permission = try #require(permissions[login], "Unexpected permission lookup for \(login)")
                    response = ["permission": permission, "role_name": permission, "user": Self.user(login)]
                } else if method == "DELETE", route.hasPrefix("\(issueRoute)/labels/") {
                    let name = try #require(String(route.dropFirst("\(issueRoute)/labels/".count))
                        .removingPercentEncoding)
                    labels.removeAll { $0 == name }
                    revision += 1
                    response = [:]
                } else {
                    throw AgentFailure("Unexpected GH-120 request: \(method) \(path)")
                }
            }
            return try JSONSerialization.data(withJSONObject: response)
        }

        private static func connection(_ nodes: [[String: Any]]) -> [String: Any] {
            [
                "nodes": nodes, "edges": nodes.map { ["node": $0] }, "totalCount": nodes.count,
                "pageInfo": ["hasNextPage": false, "hasPreviousPage": false,
                             "startCursor": NSNull(), "endCursor": NSNull()],
            ]
        }
    }

    private struct External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            throw AgentFailure("This fixture should not produce build evidence.")
        }
    }

    private struct Checks: CheckRunner {
        func runChecks(in directory: URL, only suite: String?) async -> CheckOutput {
            Issue.record("This fixture should not start build checks.")
            return CheckOutput(passed: false, summary: "Unexpected build checks", log: "")
        }
    }

    private struct WorkspaceStub: Workspace {
        let root: URL
        var testArea: String { "Tests/" }
        var agentContext: String { "" }
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        func existingComponents() -> [String] { [] }
        func head(of directory: URL) async throws -> String { String(repeating: "a", count: 40) }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        func removeWorktree(for id: NodeID) async throws {}
        func abortRebase(_ directory: URL) async throws {}
        func prepareBuild(in directory: URL) async throws {
            throw AgentFailure("This fixture must not build.")
        }
        func createWorktree(for id: NodeID) async throws -> URL {
            throw AgentFailure("This fixture must not create a leaf working copy.")
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("This fixture must not commit code.")
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            throw AgentFailure("This fixture must not rebase code.")
        }
        func resetForRework(_ directory: URL) async throws {
            throw AgentFailure("This fixture must not discard implementation work.")
        }
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("This fixture must not land code.")
        }
    }
}
