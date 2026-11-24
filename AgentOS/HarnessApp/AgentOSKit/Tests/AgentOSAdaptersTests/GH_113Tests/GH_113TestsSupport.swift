import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

extension GH_113Tests {
    struct VerificationWorkspace: Workspace {
        let tip: String
        private var unused: UnusedDependencies { UnusedDependencies() }
        var testArea: String { unused.testArea }
        var agentContext: String { unused.agentContext }
        func branch(for id: NodeID) -> String { unused.branch(for: id) }
        func worktree(for id: NodeID) -> URL { unused.worktree(for: id) }
        func testFolder(for spec: NodeSpec) -> String { unused.testFolder(for: spec) }
        func existingComponents() -> [String] { unused.existingComponents() }
        func prepare() throws { try unused.prepare() }
        func createWorktree(for id: NodeID) throws -> URL { try unused.createWorktree(for: id) }
        func removeWorktree(for id: NodeID) throws { try unused.removeWorktree(for: id) }
        func commitAll(in directory: URL, message: String, author: String) throws -> String? {
            try unused.commitAll(in: directory, message: message, author: author)
        }
        func changedFiles(in directory: URL) throws -> [String] { try unused.changedFiles(in: directory) }
        func rebaseOntoMain(_ directory: URL) throws -> RebaseResult { try unused.rebaseOntoMain(directory) }
        func abortRebase(_ directory: URL) throws { try unused.abortRebase(directory) }
        func resetForRework(_ directory: URL) throws { try unused.resetForRework(directory) }
        func landOnMain(_ id: NodeID) throws -> String { try unused.landOnMain(id) }
        func requirementWorktree(for requirement: NodeIdentity) -> URL { worktree(for: requirement.nodeID) }
        func requirementIsMerged(_ requirement: NodeIdentity) -> Bool { false }
        func head(of directory: URL) -> String { tip }
        func prepareBuild(in directory: URL) {}
    }

    actor RecordingVerification: CheckRunner, RequirementPublisher {
        private(set) var checkedSuites: [String?] = []
        func runChecks(in directory: URL, only testTarget: String?) -> CheckOutput {
            checkedSuites.append(testTarget)
            return CheckOutput(passed: true, summary: "Full checks passed", log: "Full checks passed")
        }
        func publish(requirement: NodeIdentity, branch: String, commit: String) throws {
            throw AgentFailure("A flag or publication failure without a publication retry must not publish")
        }
    }

    struct VerificationArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) -> StoredArtifact {
            StoredArtifact(path: "memory/\(name)", sha256: Hashing.sha256(contents))
        }
    }

    actor GitHub: GitHubTransport {
        static let repo = "owner/project"
        let issueClosed: Bool
        private var labels: Set<String> = ["bug", "agentos: Ready"]
        private(set) var labelWrites: [String] = []
        private(set) var boardStatus = "Ready"
        private(set) var boardWrites: [String] = []
        var statusLabels: Set<String> { labels.filter { $0.hasPrefix("agentos: ") } }

        init(issueClosed: Bool = false) { self.issueClosed = issueClosed }

        func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
            let route = String(path.split(separator: "?")[0])
            let sent = try body.map {
                try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
            } ?? [:]
            let issues = "repos/\(Self.repo)/issues"
            let item = "\(issues)/215"
            let result: Any
            switch (method, route) {
            case ("GET", "user"):
                result = ["login": "harness", "type": "User"]
            case ("GET", issues):
                result = issueClosed ? [] : [issue()]
            case ("GET", item):
                result = issue()
            case ("GET", "\(item)/comments"), ("GET", "\(item)/events"):
                result = []
            case ("POST", "\(item)/labels"):
                let added = try #require(sent["labels"] as? [String])
                labels.formUnion(added)
                labelWrites.append(contentsOf: added)
                result = labels.map { ["name": $0] }
            case ("DELETE", _) where route.hasPrefix("\(item)/labels/"):
                let encoded = String(route.dropFirst("\(item)/labels/".count))
                labels.remove(try #require(encoded.removingPercentEncoding))
                result = [:] as [String: String]
            case ("POST", "graphql"):
                result = try graphql(sent)
            default:
                throw AgentFailure("Unexpected in-memory GitHub request: \(method) \(path)")
            }
            return try JSONSerialization.data(withJSONObject: result)
        }

        private func issue() -> [String: Any] {
            [
                "id": 1215, "number": 215, "title": "Requirement 215",
                "body": "Verify requirement\n\n## Acceptance criteria\n- [ ] Works",
                "state": issueClosed ? "closed" : "open", "labels": labels.sorted().map { ["name": $0] },
                "user": ["login": "Tester", "type": "User"],
                "updated_at": "revision-\(labelWrites.count)"
            ]
        }

        private func graphql(_ sent: [String: Any]) throws -> [String: Any] {
            let query = try #require(sent["query"] as? String)
            let variables = try #require(sent["variables"] as? [String: Any])
            if query.contains("editor") {
                let description = try #require(issue()["body"] as? String)
                return ["data": ["repository": ["issue": [
                    "body": description, "editor": NSNull(), "lastEditedAt": NSNull()
                ]]]]
            }
            if query.contains("repositoryOwner") {
                return ["data": ["repositoryOwner": ["projectV2": [
                    "id": "project-7", "title": "Delivery",
                    "field": ["id": "status-field",
                              "options": ["Ready", "In review", "Done"].map { ["id": $0, "name": $0] }]
                ]]]]
            }
            if query.contains("projectItems") {
                return ["data": ["repository": ["issue": [
                    "id": "issue-215", "projectItems": ["nodes": [[
                        "id": "card-215", "project": ["id": "project-7"],
                        "fieldValueByName": ["name": boardStatus]
                    ]]]
                ]]]]
            }
            if query.contains("updateProjectV2ItemFieldValue") {
                boardStatus = try #require(variables["option"] as? String)
                boardWrites.append(boardStatus)
                return ["data": ["updateProjectV2ItemFieldValue": ["projectV2Item": ["id": "card-215"]]]]
            }
            throw AgentFailure("Unexpected in-memory GraphQL operation")
        }
    }

    struct UnusedDependencies: Workspace, ExternalDependencySource, ArtifactStore,
                               CheckRunner, Decomposer, TestAuthor, Implementer {
        private var unexpected: AgentFailure { AgentFailure("Status projection must not run product work") }
        var testArea: String { "Tests/" }
        var agentContext: String { "" }
        func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        func worktree(for id: NodeID) -> URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        func existingComponents() -> [String] { [] }
        func prepare() throws { throw unexpected }
        func createWorktree(for id: NodeID) throws -> URL { throw unexpected }
        func removeWorktree(for id: NodeID) throws { throw unexpected }
        func commitAll(in directory: URL, message: String, author: String) throws -> String? { throw unexpected }
        func head(of directory: URL) throws -> String { throw unexpected }
        func changedFiles(in directory: URL) throws -> [String] { throw unexpected }
        func rebaseOntoMain(_ directory: URL) throws -> RebaseResult { throw unexpected }
        func abortRebase(_ directory: URL) throws { throw unexpected }
        func resetForRework(_ directory: URL) throws { throw unexpected }
        func landOnMain(_ id: NodeID) throws -> String { throw unexpected }
        func prepareBuild(in directory: URL) throws { throw unexpected }
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact { throw unexpected }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("Status projection unexpectedly requested a check")
            return CheckOutput(passed: false, summary: "Unexpected check", log: "")
        }
        func proposeChildren(_ request: BreakdownRequest) throws -> Breakdown { throw unexpected }
        func writeAcceptanceTests(_ task: AgentTask) throws -> AgentReport { throw unexpected }
        func implement(_ task: AgentTask) throws -> AgentReport { throw unexpected }
    }
}
