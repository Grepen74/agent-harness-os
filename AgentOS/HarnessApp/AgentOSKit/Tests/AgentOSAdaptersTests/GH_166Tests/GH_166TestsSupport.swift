import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_166Tests {
    final class Fixture: Sendable {
        let directory: URL
        let ledger: Ledger
        let root: NodeSpec
        let completed: NodeSpec
        let pending: NodeSpec
        let nested: NodeSpec
        let lastDescendant: NodeSpec
        let integration: NodeSpec
        let agents: Agents
        let reconciler: Reconciler

        init(after: AfterCase = .omitted, integrationPhase: Phase = .specified,
             pendingPhase: Phase = .specified, compositeSibling: Bool = false,
             marked: Bool = true, markFalse: Bool = false) async throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "GH-166-\(UUID().uuidString)")
            ledger = try Ledger()
            root = GH_166Tests.spec("parent", kind: .composite)
            completed = GH_166Tests.spec("completed", parent: root.id)
            var waiting = GH_166Tests.spec(
                "pending", parent: root.id, kind: compositeSibling ? .composite : .leaf)
            if after == .duplicateFingerprint {
                waiting.title = completed.title
                waiting.intent = completed.intent
                waiting.acceptanceCriteria = completed.acceptanceCriteria
            }
            pending = waiting
            nested = GH_166Tests.spec("nested", parent: pending.id, kind: .composite)
            lastDescendant = GH_166Tests.spec("last", parent: nested.id)
            var last = GH_166Tests.spec("combined", parent: root.id)
            if marked { last.integration = true }
            else if markFalse { last.integration = false }
            switch after {
            case .omitted: break
            case .empty: last.after = []
            case .onlyProven, .duplicateFingerprint: last.after = [completed.specHash]
            case .missingHash: last.after = ["no-current-child-has-this-fingerprint"]
            }
            integration = last
            agents = Agents(ledger: ledger, sibling: pending.id)
            reconciler = Reconciler(
                ledger: ledger, tracker: Tracker(), external: External(),
                workspace: TestWorkspace(directory: directory), artifacts: Artifacts(), checks: Checks(),
                team: AgentTeam(name: "GH-166 observed starts", decomposer: agents,
                                testAuthor: agents, implementer: agents),
                policy: Policy(maxParallelAgents: 4, guesswork: .ask, avoidOverlappingWork: false))

            let otherCompleted = GH_166Tests.spec("also-completed", parent: root.id)
            var events = [
                Self.created(root), Self.created(completed), Self.created(otherCompleted), Self.created(pending),
            ]
            events += [
                Self.event(root.id, .phaseChanged(to: .split)),
                Self.event(completed.id, .landed(commit: "completed-commit")),
                Self.event(completed.id, .phaseChanged(to: .proven)),
                Self.event(otherCompleted.id, .phaseChanged(to: .proven)),
            ]
            if compositeSibling {
                let first = GH_166Tests.spec("first", parent: pending.id)
                let deep = GH_166Tests.spec("deep", parent: nested.id)
                events += [
                    Self.created(first), Self.created(nested), Self.created(deep), Self.created(lastDescendant),
                    Self.event(pending.id, .phaseChanged(to: .split)),
                    Self.event(nested.id, .phaseChanged(to: .split)),
                    Self.event(first.id, .phaseChanged(to: .proven)),
                    Self.event(deep.id, .phaseChanged(to: .proven)),
                    Self.event(lastDescendant.id, .flagSet(.needsInput, reason: "Waiting for the fixture to prove it")),
                ]
            } else {
                events += [
                    Self.event(pending.id, .phaseChanged(to: pendingPhase)),
                    Self.event(pending.id, .flagSet(pendingPhase == .landing ? .escalated : .needsInput,
                                                  reason: "Waiting for the fixture to prove it")),
                ]
            }
            events += [Self.created(integration), Self.event(integration.id, .phaseChanged(to: integrationPhase))]
            try await ledger.append(events)
        }

        func open(_ gate: Gate) async throws {
            try await ledger.append([
                LedgerEvent(node: integration.id, by: .human("Test reviewer"), kind: .gateOpened(gate)),
            ])
        }

        func prove(_ id: NodeID) async throws {
            try await ledger.append([
                Self.event(id, .flagCleared(.needsInput)),
                Self.event(id, .landed(commit: "landed-\(id)")),
                Self.event(id, .phaseChanged(to: .proven)),
            ])
        }

        func revise(dropping: [NodeID] = [], adding: NodeSpec? = nil) async throws {
            let state = await ledger.workingState()
            let parent = try #require(state.nodes[root.id])
            let kept = parent.children.filter { !dropping.contains($0) }.compactMap { state.nodes[$0]?.spec }
            var events = [
                Self.event(root.id, .replanned(spec: root)),
                Self.event(root.id, .breakdownRevised(kept: kept, dropped: dropping)),
            ]
            if let adding {
                events += [
                    Self.created(adding),
                    Self.event(adding.id, .flagSet(.needsInput, reason: "New current child is not yet Proven")),
                ]
            }
            events.append(Self.event(root.id, .phaseChanged(to: .split)))
            try await ledger.append(events)
        }

        func settle() async throws {
            try await withHangGuard("GH-166 reconciler reaching an observable idle state") {
                while true {
                    try Task.checkCancellation()
                    let report = await self.reconciler.runRound(waitForAgents: true)
                    try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                    if report.isIdle { return }
                }
            }
        }

        func starts(of role: AgentRole) async -> [RecordedEvent] {
            await ledger.records(for: integration.id).filter {
                if case .runStarted(_, let startedRole) = $0.event.kind { return startedRole == role }
                return false
            }
        }

        func removeFiles() {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Could not remove GH-166 fixture scratch files: \(error)") }
        }

        private static func created(_ spec: NodeSpec) -> LedgerEvent {
            event(spec.id, .nodeCreated(spec: spec, ticket: String(spec.id.dropFirst(3))))
        }

        private static func event(_ id: NodeID, _ kind: EventKind) -> LedgerEvent {
            LedgerEvent(node: id, by: .reconciler, kind: kind)
        }
    }

    actor Agents: Decomposer, TestAuthor, AgentOSCore.Implementer {
        struct Call: Sendable {
            let node: NodeID
            let role: AgentRole
            let siblingSubtreePhases: [Phase]
        }
        let ledger: Ledger
        let sibling: NodeID
        private(set) var calls: [Call] = []

        init(ledger: Ledger, sibling: NodeID) {
            self.ledger = ledger
            self.sibling = sibling
        }

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH-166 supplies the approved breakdown through the ledger")
        }

        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            await observe(task, role: .testAuthor)
        }

        func implement(_ task: AgentTask) async throws -> AgentReport {
            await observe(task, role: .implementer)
        }

        private func observe(_ task: AgentTask, role: AgentRole) async -> AgentReport {
            let state = await ledger.workingState()
            calls.append(Call(node: task.spec.id, role: role,
                              siblingSubtreePhases: state.subtree(of: sibling).map(\.phase)))
            return AgentReport(questions: ["The start was observed; leave further work for a person."])
        }
    }

    private struct TestWorkspace: Workspace {
        let directory: URL
        var testArea: String { "Tests/" }
        var agentContext: String { "" }
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory.appending(path: id) }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        func createWorktree(for id: NodeID) async throws -> URL { worktree(for: id) }
        func removeWorktree(for id: NodeID) async throws {}
        func head(of directory: URL) async throws -> String { "tests-commit" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
        func existingComponents() -> [String] { [] }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("GH-166 agents ask for input immediately after their start is observed")
        }
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("GH-166 does not submit integration changes for landing")
        }
    }

    private actor Tracker: TrackerAdapter {
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async {}
        func comment(on key: String, _ text: String) async {}
        func setStatus(of key: String, to status: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("GH-166 creates current children with ledger events")
        }
    }

    private struct External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct Checks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: false, summary: "GH-166 stops at agent start", log: "No integration change submitted")
        }
    }

    private struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }
}
