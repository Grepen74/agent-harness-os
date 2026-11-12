// API contract: TrackerAdapter.createsChildTickets: Bool selects ticket-backed child identity.
// When false, Reconciler preserves positional IDs; Ledger reload preserves all recorded identities.

import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

@Suite
struct GH_27_2Tests {
    @Test(arguments: [false, true])
    func ticketlessBreakdownKeepsPositionalChildIDs(usingPreview: Bool) async throws {
        let parent = Self.spec("wn-GH-15", kind: .composite)
        let ledger = try Ledger()
        var events = [
            LedgerEvent(node: parent.id, by: .human("Alice"), kind: .nodeCreated(spec: parent, ticket: "GH-15")),
            LedgerEvent(node: parent.id, by: .human("Alice"), kind: .gateOpened(.breakdown)),
        ]
        if usingPreview {
            let children = Self.proposals.enumerated().map { index, proposal in
                NodeSpec(
                    id: "\(parent.id).\(index + 1)", parent: parent.id, kind: .leaf,
                    title: proposal.title, intent: "Part of \(parent.title)",
                    acceptanceCriteria: proposal.acceptanceCriteria
                )
            }
            events.append(LedgerEvent(
                node: parent.id, by: .reconciler,
                kind: .previewRecorded(ticket: "GH-15", number: 1, specHash: parent.specHash, proposal: children)
            ))
        }
        try await ledger.append(events)
        let reconciler = Reconciler(
            ledger: ledger, tracker: TicketlessTracker(), external: NoExternalDependencies(),
            workspace: BreakdownWorkspace(), artifacts: UnusedArtifacts(), checks: UnusedChecks(),
            team: AgentTeam(
                name: "GH_27_2", decomposer: FixedDecomposer(expectPreview: usingPreview),
                testAuthor: UnusedTestAuthor(), implementer: UnusedImplementer()
            )
        )

        let report = await reconciler.runRound(waitForAgents: true)

        #expect(report.safeStop == nil)
        let state = await ledger.workingState()
        let expectedIDs = ["wn-GH-15.1", "wn-GH-15.2", "wn-GH-15.3"]
        #expect(state.nodes[parent.id]?.phase == .split)
        #expect(state.nodes[parent.id]?.children == expectedIDs)
        #expect(Set(state.nodes.keys) == Set([parent.id] + expectedIDs))
        for (index, id) in expectedIDs.enumerated() {
            let child = try #require(state.nodes[id])
            #expect(child.id == id)
            #expect(child.spec.parent == parent.id)
            #expect(child.spec.title == Self.proposals[index].title)
        }
        let creations = await ledger.allRecords().compactMap { record -> NodeSpec? in
            guard case .nodeCreated(let spec, _) = record.event.kind, spec.parent != nil else { return nil }
            #expect(record.event.node == spec.id)
            return spec
        }
        #expect(creations.map(\.id) == expectedIDs)
    }

    @Test
    func loadingAnExistingLedgerPreservesRecordedIDsTicketsAndReferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GH_27_2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.jsonl")
        let original = try Ledger(store: FileLedgerStore(fileURL: file))
        let root = Self.spec("wn-GH-15", kind: .composite)
        let first = Self.spec("wn-GH-15.1", parent: root.id, kind: .composite)
        let second = Self.spec("wn-GH-15.2", parent: root.id, dependsOn: [first.id, "BACKEND-42"])
        let nested = Self.spec("wn-GH-15.1.1", parent: first.id, dependsOn: [second.id])
        let ticketNamed = Self.spec("wn-GH-99", dependsOn: [nested.id])
        let dropped = Self.spec("wn-GH-15.3", parent: root.id)
        let preview = Self.spec("wn-GH-15.4", parent: root.id, dependsOn: [nested.id, "BACKEND-42"])
        let dependency = TypedLink(from: second.id, type: .dependsOn, to: first.id)
        let external = TypedLink(from: second.id, type: .dependsOn, to: "BACKEND-42")
        let fixtures: [(NodeID?, EventKind)] = [
            (root.id, .nodeCreated(spec: root, ticket: "GH-15")),
            (first.id, .nodeCreated(spec: first, ticket: "GH-18")),
            (second.id, .nodeCreated(spec: second, ticket: "GH-21")),
            (nested.id, .nodeCreated(spec: nested, ticket: "GH-22")),
            (ticketNamed.id, .nodeCreated(spec: ticketNamed, ticket: "GH-99")),
            (dropped.id, .nodeCreated(spec: dropped, ticket: "GH-23")),
            (second.id, .linkAdded(dependency)),
            (second.id, .linkAdded(external)),
            (root.id, .previewRecorded(ticket: "GH-15", number: 2, specHash: root.specHash, proposal: [preview])),
            (first.id, .replanned(spec: first)),
            (root.id, .breakdownRevised(kept: [first, second], dropped: [dropped.id])),
            (root.id, .phaseChanged(to: .split)),
        ]
        try await original.append(fixtures.map { node, kind in
            LedgerEvent(node: node, by: .reconciler, kind: kind, at: Date(timeIntervalSince1970: 1_700_000_000))
        })
        let before = await original.allRecords()
        let bytesBefore = try Data(contentsOf: file)
        let stateBefore = await original.workingState()

        let reloaded = try Ledger(store: FileLedgerStore(fileURL: file))

        let after = await reloaded.allRecords()
        // Compare identity-bearing fields, not whole records or timestamp encodings.
        #expect(after.map(Self.identity) == before.map(Self.identity))
        #expect(try Data(contentsOf: file) == bytesBefore)
        #expect(await reloaded.verifyChain().isIntact)
        let state = await reloaded.workingState()
        #expect(state.creationOrder == stateBefore.creationOrder)
        #expect(Set(state.nodes.keys) == Set([root.id, first.id, second.id, nested.id, ticketNamed.id]))
        for id in stateBefore.creationOrder {
            let expected = try #require(stateBefore.nodes[id])
            let actual = try #require(state.nodes[id])
            #expect(actual.spec == expected.spec)
            #expect(actual.ticket == expected.ticket)
            #expect(actual.children == expected.children)
            #expect(actual.links == expected.links)
        }
        #expect(state.previews["GH-15"]?.proposal == [preview])
        #expect(state.superseded == stateBefore.superseded)
        #expect(state.nodes[root.id]?.children == [first.id, second.id])
        #expect(state.nodes[first.id]?.children == [nested.id])
        #expect(state.nodes[second.id]?.links == [dependency, external])
    }

    private struct RecordIdentity: Equatable {
        let node: NodeID?
        var specs: [NodeSpec] = []
        var tickets: [String] = []
        var links: [TypedLink] = []
        var dropped: [NodeID] = []
    }

    private static func identity(_ record: RecordedEvent) -> RecordIdentity {
        var result = RecordIdentity(node: record.event.node)
        switch record.event.kind {
        case .nodeCreated(let spec, let ticket):
            result.specs = [spec]
            result.tickets = [ticket]
        case .previewRecorded(let ticket, _, _, let proposal):
            result.specs = proposal
            result.tickets = [ticket]
        case .linkAdded(let link):
            result.links = [link]
        case .replanned(let spec):
            result.specs = [spec]
        case .breakdownRevised(let kept, let dropped):
            result.specs = kept
            result.dropped = dropped
        default:
            break
        }
        return result
    }

    private static func spec(
        _ id: NodeID, parent: NodeID? = nil, kind: NodeKind = .leaf, dependsOn: [String] = []
    ) -> NodeSpec {
        NodeSpec(
            id: id, parent: parent, kind: kind, title: "Work \(id)", intent: "Preserve identity",
            acceptanceCriteria: ["Recorded references stay unchanged"], dependsOn: dependsOn
        )
    }

    private static let proposals = [
        ChildProposal(title: "Store greetings", acceptanceCriteria: ["Greetings can be saved"]),
        ChildProposal(title: "Read greetings", acceptanceCriteria: ["Saved greetings can be read"]),
        ChildProposal(title: "Display greetings", acceptanceCriteria: ["Greetings can be displayed"]),
    ]

    private struct TicketlessTracker: TrackerAdapter {
        let createsChildTickets = false

        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async {}
        func comment(on key: String, _ text: String) async {}
        func setStatus(of key: String, to status: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by author: Participant) async throws -> String {
            // A local reference is not a real child ticket key and must not determine the node ID.
            "local-reference-\(spec.id)"
        }
    }

    private struct FixedDecomposer: Decomposer {
        let expectPreview: Bool

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            #expect(!expectPreview, "An accepted preview must be reused")
            return Breakdown(children: GH_27_2Tests.proposals)
        }
    }

    private struct NoExternalDependencies: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct BreakdownWorkspace: Workspace {
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("GH_27_2-unused-\(id)")
        }
        func createWorktree(for id: NodeID) async throws -> URL { throw unexpected() }
        func removeWorktree(for id: NodeID) async throws { throw unexpected() }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { throw unexpected() }
        func head(of directory: URL) async throws -> String { throw unexpected() }
        func changedFiles(in directory: URL) async throws -> [String] { throw unexpected() }
        var testArea: String { "Tests/AgentOSAdaptersTests/" }
        func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { throw unexpected() }
        func abortRebase(_ directory: URL) async throws { throw unexpected() }
        func resetForRework(_ directory: URL) async throws { throw unexpected() }
        func landOnMain(_ id: NodeID) async throws -> String { throw unexpected() }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws { throw unexpected() }

        private func unexpected() -> AgentFailure {
            Issue.record("Breakdown must not mutate a workspace")
            return AgentFailure("Unexpected workspace operation during GH_27_2 breakdown")
        }
    }

    private struct UnusedArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            Issue.record("Breakdown must not write artifacts")
            throw AgentFailure("Unexpected artifact")
        }
    }

    private struct UnusedChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("Breakdown must not run implementation checks")
            return CheckOutput(passed: false, summary: "Unexpected check", log: "")
        }
    }

    private struct UnusedTestAuthor: TestAuthor {
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            Issue.record("Only parent breakdown should advance in this round")
            throw AgentFailure("Unexpected test author")
        }
    }

    private struct UnusedImplementer: Implementer {
        func implement(_ task: AgentTask) async throws {
            Issue.record("Breakdown must not start implementation")
            throw AgentFailure("Unexpected implementer")
        }
    }
}
