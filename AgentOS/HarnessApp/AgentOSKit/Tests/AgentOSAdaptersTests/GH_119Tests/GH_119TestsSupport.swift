import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_119Tests {
    static func tracker(_ github: GitHub, ledger: Ledger) -> GitHubIssuesTracker {
        GitHubIssuesTracker(repo: "o/r", transport: github, ledger: ledger, listInterval: .zero)
    }

    static func fixture() throws -> Fixture { try Fixture() }

    static func reconciler(ledger: Ledger, tracker: any TrackerAdapter,
                                      agents: Agents, root: URL) -> Reconciler {
        Reconciler(ledger: ledger, tracker: tracker, external: External(), workspace: WorkspaceFake(root: root),
                   artifacts: FileArtifactStore(directory: root.appending(path: "artifacts")), checks: Checks(),
                   team: AgentTeam(name: "Description tests", decomposer: agents, testAuthor: agents, implementer: agents),
                   policy: Policy(guesswork: .ask))
    }

    struct Fixture: Sendable {
        let github = GitHub()
        let agents = Agents()
        let root: URL
        let ledgerURL: URL
        let ledger: Ledger
        let tracker: GitHubIssuesTracker
        let reconciler: Reconciler

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH-119-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            ledgerURL = root.appending(path: "ledger.jsonl")
            ledger = try Ledger(store: FileLedgerStore(fileURL: ledgerURL))
            tracker = GH_119Tests.tracker(github, ledger: ledger)
            reconciler = GH_119Tests.reconciler(ledger: ledger, tracker: tracker, agents: agents, root: root)
        }

        func adoptWithoutGates() async throws {
            let spec = NodeSpec(id: "wn-GH-7", parent: nil, kind: .composite, title: "Requirement",
                                intent: "Accepted requirement", acceptanceCriteria: ["The requirement works"])
            try await ledger.append([LedgerEvent(node: spec.id, by: .human("maintainer"),
                                                 kind: .nodeCreated(spec: spec, ticket: "GH-7"))])
        }

        func round() async throws {
            try await withHangGuard("Description reconciler round") {
                let report = await reconciler.runRound(waitForAgents: true)
                #expect(report.safeStop == nil)
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    actor Agents: Decomposer, TestAuthor, Implementer {
        private(set) var breakdowns: [BreakdownRequest] = []
        private(set) var authoredTasks: [AgentTask] = []

        func proposeChildren(_ request: BreakdownRequest) -> Breakdown {
            breakdowns.append(request)
            return Breakdown(children: [ChildProposal(title: request.spec.title,
                                                       acceptanceCriteria: request.spec.acceptanceCriteria)])
        }

        func writeAcceptanceTests(_ task: AgentTask) -> AgentReport {
            authoredTasks.append(task)
            return AgentReport(questions: ["A test-only question stops before committing any files"])
        }

        func implement(_ task: AgentTask) throws -> AgentReport {
            throw AgentFailure("This fixture must not start implementation")
        }
    }

    struct External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    struct Checks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "Fixture check passed", log: "")
        }
    }

    struct WorkspaceFake: Workspace {
        let root: URL
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        func createWorktree(for id: NodeID) async throws -> URL {
            let directory = worktree(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        func removeWorktree(for id: NodeID) async throws {
            let directory = worktree(for: id)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { nil }
        func head(of directory: URL) async throws -> String { "fixture-head" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("This fixture must not land code")
        }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    /// A single issue with real REST/GraphQL field names. Requests never leave this actor.
    actor GitHub: GitHubTransport {
        private(set) var currentDescription = "Accepted requirement"
        private var editor: String?
        private var revision = 0
        private var editedAt: String?
        private var labels: [String] = []
        private var events: [[String: Any]] = []
        private var permissions: [String: String] = ["maintainer": "write", "outsider": "read", "harness-user": "write"]
        private var failedPermissions: Set<String> = []
        private var permissionReads: [String: Int] = [:]
        private(set) var postedComments: [String] = []

        func setPermission(_ permission: String?, for login: String) {
            if let permission {
                permissions[login] = permission
                failedPermissions.remove(login)
            } else {
                failedPermissions.insert(login)
            }
        }

        func permissionRequests(for login: String) -> Int { permissionReads[login, default: 0] }

        func edit(_ description: String, by login: String) {
            currentDescription = description
            editor = login
            revision += 1
            editedAt = timestamp
        }

        func label(_ command: HarnessCommand, by login: String) {
            revision += 1
            labels.removeAll { $0 == command.label }
            labels.append(command.label)
            events.append(["id": 100 + revision, "event": "labeled", "actor": user(login),
                           "label": ["name": command.label], "created_at": timestamp])
        }

        func clearHarnessLabels() {
            for label in labels where label.hasPrefix("harness:") {
                revision += 1
                events.append(["id": 100 + revision, "event": "unlabeled", "actor": user("harness-user"),
                               "label": ["name": label], "created_at": timestamp])
            }
            labels.removeAll { $0.hasPrefix("harness:") }
        }

        private var timestamp: String { String(format: "2026-01-01T00:%02d:%02dZ", revision / 60, revision % 60) }
        private var issueBody: String { currentDescription + "\n\n## Acceptance criteria\n- The requirement works" }
        private func user(_ login: String) -> [String: String] { ["login": login, "type": "User"] }
        private var issue: [String: Any] {
            ["id": 1007, "node_id": "I_7", "number": 7, "title": "Requirement", "body": issueBody, "state": "open",
             "labels": labels.map { ["name": $0] }, "user": user("outsider"), "created_at": "2025-12-31T00:00:00Z",
             "updated_at": timestamp]
        }

        func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
            let route = String(path.split(separator: "?", maxSplits: 1)[0])
            let parts = route.split(separator: "/").map(String.init)
            let sent: [String: Any]
            if let body {
                sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            } else {
                sent = [:]
            }
            func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

            if method == "GET", route == "user" { return try json(user("harness-user")) }
            if method == "GET", parts.count == 6, parts[3] == "collaborators", parts[5] == "permission" {
                let login = parts[4]
                permissionReads[login, default: 0] += 1
                if failedPermissions.contains(login) { throw AgentFailure("Permission unavailable for \(login)") }
                let permission = permissions[login] ?? "none"
                return try json(["permission": permission, "role_name": permission, "user": user(login)])
            }
            if method == "POST", route == "graphql" {
                var value: [String: Any] = [
                    "id": "I_7", "number": 7, "title": "Requirement", "body": issueBody,
                    "editor": editor.map { user($0) as Any } ?? NSNull(),
                    "author": user("outsider"), "updatedAt": timestamp,
                    "lastEditedAt": editedAt.map { $0 as Any } ?? NSNull(),
                    "createdAt": "2025-12-31T00:00:00Z",
                ]
                let timeline = events.map { event -> [String: Any] in
                    ["__typename": event["event"] as? String == "labeled" ? "LabeledEvent" : "UnlabeledEvent",
                     "actor": event["actor"]!, "label": event["label"]!, "createdAt": event["created_at"]!]
                }
                value["timelineItems"] = ["nodes": timeline, "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]
                return try json(["data": ["repository": ["issue": value], "node": value, "nodes": [value],
                                         "viewer": user("harness-user")]])
            }
            switch (method, route) {
            case ("GET", "repos/o/r/issues"): return try json(path.contains("page=2") ? [] : [issue])
            case ("GET", "repos/o/r/issues/7"): return try json(issue)
            case ("GET", "repos/o/r/issues/7/events"): return try json(path.contains("page=2") ? [] : events)
            case ("GET", "repos/o/r/issues/7/comments"):
                let comments: [[String: Any]] = postedComments.enumerated().map { index, text in
                    ["id": 500 + index, "body": text, "user": user("harness-user"), "created_at": timestamp]
                }
                return try json(path.contains("page=2") ? [] : comments)
            case ("POST", "repos/o/r/labels"): return try json([:])
            case ("POST", "repos/o/r/issues/7/comments"):
                let text = try #require(sent["body"] as? String)
                postedComments.append(text)
                revision += 1
                return try json(["id": 500 + postedComments.count, "body": text])
            case ("POST", "repos/o/r/issues/7/labels"):
                let names = try #require(sent["labels"] as? [String])
                for name in names where !labels.contains(name) { labels.append(name) }
                revision += 1
                return try json(labels.map { ["name": $0] })
            default:
                if method == "DELETE", parts.count == 7, parts[5] == "labels" {
                    let name = parts[6].removingPercentEncoding ?? parts[6]
                    labels.removeAll { $0 == name }
                    revision += 1
                    events.append(["id": 100 + revision, "event": "unlabeled", "actor": user("harness-user"),
                                   "label": ["name": name], "created_at": timestamp])
                    return try json([])
                }
                throw AgentFailure("Unsupported fixture request: \(method) \(path)")
            }
        }
    }
}
