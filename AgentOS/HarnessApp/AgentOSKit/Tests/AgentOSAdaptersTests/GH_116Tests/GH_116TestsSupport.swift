import AgentOSAdapters
@testable import AgentOSCore
import AgentOSTestSupport
import Foundation
import Synchronization
import Testing

extension GH_116Tests {
    final class GH116Clock: Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 1_735_689_600))
        var now: Date { value.withLock { $0 } }
        func advance(by seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    actor GH116GitHub: GitHubTransport {
        private var issues: [[String: Any]] = []
        private var comments: [Int: [[String: Any]]] = [:]
        private var permissions: [String: String] = [:]
        private var failures: [String: String] = [:]
        private var reads: [String: Int] = [:]
        private var sequence = 0
        private var labels: [Int: [String]] = [:]

        func addIssue(_ number: Int, parent: Int? = nil) {
            let parentLine = parent.map { "\n\nParent: #\($0)" } ?? ""
            issues.append([
                "id": 1000 + number, "number": number, "title": "Greeting",
                "body": "Greet the user\n\n## Acceptance criteria\n- The greeting is visible\(parentLine)",
                "state": "open", "labels": [], "user": ["login": "owner", "type": "User"],
                "updated_at": "revision-0",
            ])
        }

        func setPermission(_ permission: String, for login: String) { permissions[login] = permission }
        func failNextPermission(for login: String, with reason: String) { failures[login] = reason }
        func permissionReads(for login: String) -> Int { reads[login, default: 0] }
        func commentBodies(on number: Int) -> [String] {
            comments[number, default: []].compactMap { $0["body"] as? String }
        }

        func addComment(_ text: String, on number: Int, by login: String, type: String = "User") {
            sequence += 1
            let date = Date(timeIntervalSince1970: 1_735_689_600 + Double(sequence))
            comments[number, default: []].append([
                "id": sequence, "body": text, "user": ["login": login, "type": type],
                "created_at": date.formatted(.iso8601),
            ])
            update(number) { $0["updated_at"] = "revision-\(sequence)" }
        }

        func signal(_ command: HarnessCommand, on number: Int) {
            labels[number, default: []].append(command.label)
            update(number) { $0["labels"] = labels[number, default: []].map { ["name": $0] } }
        }

        private func update(_ number: Int, _ operation: (inout [String: Any]) -> Void) {
            guard let index = issues.firstIndex(where: { $0["number"] as? Int == number }) else { return }
            operation(&issues[index])
        }

        func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
            let route = String(path.split(separator: "?")[0])
            let parts = route.split(separator: "/").map(String.init)
            func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
            if method == "GET", route == "user" {
                return try json(["login": "harness-user", "type": "User", "id": 42])
            }
            if method == "GET", parts.count == 6, parts[3] == "collaborators", parts[5] == "permission" {
                let login = parts[4]
                reads[login, default: 0] += 1
                if let failure = failures.removeValue(forKey: login) {
                    if failure == "malformed" { return Data("not JSON".utf8) }
                    throw AgentFailure(failure)
                }
                return try json([
                    "permission": permissions[login, default: "none"],
                    "user": ["login": login, "type": "User"],
                ])
            }
            let number = parts.count > 4 ? Int(parts[4]) : nil
            if method == "GET", parts.count == 4, parts.last == "issues" {
                return try json(path.contains("page=2") ? [] : issues)
            }
            if method == "GET", parts.count == 5, let number {
                return try json(issues.first { $0["number"] as? Int == number } ?? [:])
            }
            if method == "GET", parts.last == "comments", let number {
                return try json(path.contains("page=2") ? [] : comments[number, default: []])
            }
            if method == "GET", parts.last == "events", let number {
                return try json(labels[number, default: []].map {
                    ["event": "labeled", "actor": ["login": "maintainer", "type": "User"], "label": ["name": $0]]
                })
            }
            if method == "POST", parts.last == "comments", let number, let body {
                let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
                let text = try #require(payload["body"])
                addComment(text, on: number, by: "harness-user")
                return try json([:])
            }
            if method == "POST", parts.count == 4, parts.last == "labels" { return try json([:]) }
            if method == "POST", parts.count == 6, parts.last == "labels", let number, let body {
                let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: [String]])
                let added = try #require(payload["labels"])
                labels[number, default: []] += added.filter { !labels[number, default: []].contains($0) }
                update(number) { $0["labels"] = labels[number, default: []].map { ["name": $0] } }
                return try json(labels[number, default: []].map { ["name": $0] })
            }
            if method == "DELETE", parts.count == 7, parts[5] == "labels", let number {
                let name = parts[6].removingPercentEncoding ?? parts[6]
                labels[number, default: []].removeAll { $0 == name }
                update(number) { $0["labels"] = labels[number, default: []].map { ["name": $0] } }
                return try json([])
            }
            throw AgentFailure("Unexpected fixture request: \(method) \(path)")
        }
    }

    struct GH116Fixture: Sendable {
        let tracker: any TrackerAdapter
        let github: GH116GitHub?
        let local: LocalTracker?
        let clock: GH116Clock
        let login: String
        let userType: String
        let ledger: Ledger
        let agents: GH116Agents
        let workspace: GH116Workspace
        let reconciler: Reconciler

        var spec: NodeSpec {
            NodeSpec(id: "wn-GH-2", parent: nil, kind: .composite, title: "Greeting",
                     intent: "Greet the user", acceptanceCriteria: ["The greeting is visible"])
        }

        init(tracker: any TrackerAdapter, github: GH116GitHub? = nil, local: LocalTracker? = nil,
             clock: GH116Clock = GH116Clock(), login: String, userType: String = "User") throws {
            self.tracker = tracker
            self.github = github
            self.local = local
            self.clock = clock
            self.login = login
            self.userType = userType
            ledger = try Ledger()
            agents = GH116Agents()
            workspace = GH116Workspace(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appending(path: "fixture-\(UUID().uuidString)", directoryHint: .isDirectory))
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: GH116External(), workspace: workspace,
                artifacts: GH116Artifacts(), checks: GH116Checks(),
                team: AgentTeam(name: "GH-116", decomposer: agents, testAuthor: agents, implementer: agents),
                now: { clock.now })
        }

        func seed(_ kinds: [EventKind]) async throws {
            let events = [.nodeCreated(spec: spec, ticket: "GH-2")] + kinds
            try await ledger.append(events.map {
                LedgerEvent(node: spec.id, by: .human("maintainer"), kind: $0,
                            at: Date(timeIntervalSince1970: 1_735_000_000))
            })
        }

        func node() async -> NodeState? { await ledger.workingState().node(forTicket: "GH-2") }

        func say(_ text: String, on key: String = "GH-2") async throws {
            if let github {
                let number = try #require(Int(key.dropFirst(3)))
                await github.addComment(text, on: number, by: login, type: userType)
            } else {
                let local = try #require(local)
                await local.addComment(text, to: key, by: .human(login))
            }
        }

        func ask(_ text: String) async throws {
            if let github {
                await github.addComment(text + "\n\n" + GitHubIssuesTracker.marker, on: 2, by: "harness-user")
            } else {
                let local = try #require(local)
                await local.addComment(text, to: "GH-2", by: .reconciler)
            }
        }

        func signal(_ command: HarnessCommand) async throws {
            if let github { await github.signal(command, on: 2) }
            else {
                let local = try #require(local)
                await local.addLabel(command.label, to: "GH-2", by: .human("maintainer"))
            }
            try await withHangGuard("GH-116 \(command.label) input handling") {
                var report = RoundReport()
                await reconciler.intakeSignals(&report, waitingForPreviews: true)
            }
        }
    }

    actor GH116Agents: Decomposer, TestAuthor, Implementer {
        private(set) var requests: [BreakdownRequest] = []
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            requests.append(request)
            return Breakdown(children: [
                ChildProposal(title: request.spec.title, acceptanceCriteria: request.spec.acceptanceCriteria,
                              touches: ["Greeting"]),
            ])
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport { AgentReport() }
        func implement(_ task: AgentTask) async throws -> AgentReport { AgentReport() }
    }

    struct GH116Workspace: Workspace {
        let root: URL
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { root }
        func createWorktree(for id: NodeID) async throws -> URL { root }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { nil }
        func head(of directory: URL) async throws -> String { "fixture-head" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "fixture-landed" }
        func existingComponents() -> [String] { ["Greeting"] }
        func prepareBuild(in directory: URL) async throws {}
    }

    struct GH116External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    struct GH116Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct GH116Checks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "Passed", log: "In-memory check")
        }
    }
}
