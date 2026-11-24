import Foundation
import Testing
@testable import AgentOSCore

extension GH_141Tests {
    struct Proposer: Decomposer {
        let children: [ChildProposal]
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            Breakdown(children: children)
        }
    }

    actor Tracker: TrackerAdapter {
        private(set) var createdTickets: [String] = []
        private(set) var closedTickets: [String] = []
        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            let key = "GH-141-new-\(createdTickets.count + 1)"
            createdTickets.append(key)
            return key
        }
        func comment(on key: String, _ text: String) {}
        func setStatus(of key: String, to status: String) {}
        func close(_ key: String, saying comment: String) { closedTickets.append(key) }
    }

    struct BreakdownOnlyServices: Workspace, ExternalDependencySource, ArtifactStore, CheckRunner,
                                  TestAuthor, Implementer {
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: id)
        }
        func createWorktree(for id: NodeID) async throws -> URL {
            throw AgentFailure("GH-141 only replans; it must not start a build.")
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Unexpected commit in GH-141.")
        }
        func head(of directory: URL) async throws -> String {
            throw AgentFailure("Unexpected HEAD read in GH-141.")
        }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            throw AgentFailure("Unexpected rebase in GH-141.")
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("Unexpected landing in GH-141.")
        }
        func existingComponents() -> [String] { ["Storage", "Display"] }
        func prepareBuild(in directory: URL) async throws {
            throw AgentFailure("Unexpected build in GH-141.")
        }
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            throw AgentFailure("Unexpected artifact in GH-141.")
        }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("GH-141 must not run checks while replanning.")
            return CheckOutput(passed: false, summary: "Unexpected checks", log: "")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Unexpected test author in GH-141.")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Unexpected implementer in GH-141.")
        }
    }
}
