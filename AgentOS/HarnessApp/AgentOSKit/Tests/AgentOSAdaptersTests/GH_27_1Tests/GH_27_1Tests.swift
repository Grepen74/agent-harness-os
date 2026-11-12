// API contract: Reconciler.runRound creates tracker-backed children before recording nodeCreated,
// uses "wn-<ticket-key>" IDs, preserves parent links, and resumes partial breakdowns without duplicates.

import AgentOSAdapters
import AgentOSCore
import Foundation
import Synchronization
import Testing

@Suite
struct GH_27_1Tests {
    @Test(arguments: [false, true])
    func childTicketsExistBeforeTheirTicketNamedNodesAreRecorded(fromPreview: Bool) async throws {
        let fixture = try await Fixture(approveBreakdown: !fromPreview)
        let reconciler = fixture.makeReconciler()

        if fromPreview {
            await fixture.local.addLabel("harness:preview", to: fixture.parentTicket, by: .human("Alice"))
            let preview = await reconciler.runRound(waitForAgents: true)
            #expect(preview.safeStop == nil)
            #expect(fixture.audit.childCreations().isEmpty)
            #expect(await fixture.childTickets().isEmpty)
            await fixture.local.addLabel("harness:breakdown", to: fixture.parentTicket, by: .human("Alice"))
        }

        let report = await reconciler.runRound(waitForAgents: true)

        #expect(report.safeStop == nil)
        let creations = fixture.audit.childCreations()
        #expect(creations.count == Self.proposals.count)
        #expect(Set(creations.map(\.ticket)).count == Self.proposals.count)
        for creation in creations {
            #expect(creation.ticketAtAppend != nil, "The child ticket must already exist when its node event is persisted")
            #expect(creation.spec.id == "wn-\(creation.ticket)")
            #expect(creation.eventNode == creation.spec.id)
            let ticket = try #require(await fixture.local.ticket(creation.ticket))
            #expect(ticket.title == creation.spec.title)
        }
        let state = await fixture.ledger.workingState()
        #expect(state.nodes[Self.parentID]?.phase == .split)
        #expect(Set(state.nodes[Self.parentID]?.children ?? []) == Set(creations.map(\.spec.id)))
    }

    @Test
    func childSpecsAndRealTrackerTicketsLinkToTheirRespectiveParents() async throws {
        let fixture = try await Fixture()

        _ = await fixture.makeReconciler().runRound(waitForAgents: true)

        let creations = fixture.audit.childCreations()
        #expect(creations.count == Self.proposals.count)
        #expect(Self.parentID != "wn-\(fixture.parentTicket)")
        for creation in creations {
            #expect(creation.spec.parent == Self.parentID)
            let ticket = try #require(await fixture.local.ticket(creation.ticket))
            #expect(ticket.parentKey == fixture.parentTicket)
            #expect(creation.ticketAtAppend?.parentKey == fixture.parentTicket)
        }
    }

    @Test(arguments: [0, 1])
    func ticketCreationFailureDoesNotCreateTheFailedChildOrCompleteTheBreakdown(failingIndex: Int) async throws {
        let fixture = try await Fixture(failingTitle: Self.proposals[failingIndex].title)

        let report = await fixture.makeReconciler().runRound(waitForAgents: true)

        #expect(report.safeStop == nil)
        #expect(await fixture.tracker.creationAttempts().contains(Self.proposals[failingIndex].title))
        let creations = fixture.audit.childCreations()
        #expect(!creations.contains { $0.spec.title == Self.proposals[failingIndex].title })
        let tickets = await fixture.childTickets()
        #expect(tickets.count == creations.count)
        #expect(!tickets.contains { $0.title == Self.proposals[failingIndex].title })
        let state = await fixture.ledger.workingState()
        #expect(!state.nodes.values.contains { $0.spec.title == Self.proposals[failingIndex].title })
        let parent = try #require(state.nodes[Self.parentID])
        #expect(parent.phase != .split)
        let canRetry = parent.phase == .specified && parent.activeRun == nil
            && parent.gates.contains(.breakdown) && parent.flags.isEmpty
        let visiblyFailed = parent.flags[.escalated] != nil
            || report.actions.contains { $0.lowercased().contains("failed") || $0.lowercased().contains("stopped") }
        #expect(canRetry || visiblyFailed, "A failed breakdown must remain retryable or visibly report failure")
    }

    @Test
    func retryAfterPartialFailureKeepsExistingNodesAndTicketsEvenWithANewReconciler() async throws {
        let fixture = try await Fixture(failingTitle: Self.proposals[1].title)
        _ = await fixture.makeReconciler().runRound(waitForAgents: true)
        let alreadyCreated = fixture.audit.childCreations()
        let first = try #require(alreadyCreated.first)
        let originalTicket = try #require(await fixture.local.ticket(first.ticket))
        #expect(alreadyCreated.count < Self.proposals.count)

        await fixture.tracker.allowCreation()
        let interrupted = await fixture.ledger.workingState()
        if interrupted.nodes[Self.parentID]?.flags[.escalated] != nil {
            await fixture.local.addLabel("harness:retry", to: fixture.parentTicket, by: .human("Alice"))
        }
        let report = await fixture.makeReconciler().runRound(waitForAgents: true)

        #expect(report.safeStop == nil)
        let creations = fixture.audit.childCreations()
        let tickets = await fixture.childTickets()
        #expect(creations.count == Self.proposals.count)
        #expect(tickets.count == Self.proposals.count)
        #expect(Set(creations.map(\.spec.id)).count == Self.proposals.count)
        #expect(Set(creations.map(\.ticket)).count == Self.proposals.count)
        let attempts = await fixture.tracker.creationAttempts()
        for existing in alreadyCreated {
            #expect(attempts.filter { $0 == existing.spec.title }.count == 1)
            #expect(creations.filter { $0.spec.id == existing.spec.id && $0.ticket == existing.ticket }.count == 1)
        }
        #expect(tickets.first { $0.key == originalTicket.key }?.createdBy == originalTicket.createdBy)
        #expect(creations.filter { $0.spec.id == first.spec.id }.count == 1)
        let state = await fixture.ledger.workingState()
        #expect(state.nodes[Self.parentID]?.phase == .split)
        #expect(state.nodes[Self.parentID]?.flags[.escalated] == nil)
        #expect(state.nodes[first.spec.id]?.ticket == originalTicket.key)
        #expect(Set(state.nodes[Self.parentID]?.children ?? []) == Set(creations.map(\.spec.id)))
        for proposal in Self.proposals {
            #expect(tickets.filter { $0.title == proposal.title }.count == 1)
            #expect(creations.filter { $0.spec.title == proposal.title }.count == 1)
        }
        for creation in creations {
            #expect(creation.spec.id == "wn-\(creation.ticket)")
            #expect(creation.ticketAtAppend != nil)
        }
    }

    private static let parentID = "wn-LEGACY-27.1"
    private static let proposals = [
        ChildProposal(title: "Store a greeting", acceptanceCriteria: ["A greeting can be stored"], touches: ["Storage"]),
        ChildProposal(title: "Read a greeting", acceptanceCriteria: ["A greeting can be read"], touches: ["Reader"]),
        ChildProposal(title: "Display a greeting", acceptanceCriteria: ["A greeting can be displayed"], touches: ["Display"]),
    ]

    private struct Fixture {
        let audit: AuditStore
        let ledger: Ledger
        let local: LocalTracker
        let tracker: FailingTracker
        let parentTicket: String

        init(failingTitle: String? = nil, approveBreakdown: Bool = true) async throws {
            let audit = AuditStore()
            let local = LocalTracker(project: "GH271", store: audit)
            let parent = await local.createTicket(
                title: "Greeting workflow", description: "Store, read, and display greetings",
                acceptanceCriteria: ["The greeting workflow is available"], by: .human("Alice")
            )
            // Unrelated tickets ensure child keys cannot accidentally equal parent-derived ordinal IDs.
            for title in ["Unrelated work A", "Unrelated work B"] {
                await local.createTicket(
                    title: title, description: "Outside this breakdown",
                    acceptanceCriteria: ["Unrelated"], by: .human("Alice")
                )
            }
            let spec = NodeSpec(
                id: GH_27_1Tests.parentID, parent: nil, kind: .composite,
                title: parent.title, intent: parent.description, acceptanceCriteria: parent.acceptanceCriteria
            )
            let ledger = try Ledger(store: audit)
            var events = [LedgerEvent(node: spec.id, by: .human("Alice"), kind: .nodeCreated(spec: spec, ticket: parent.key))]
            if approveBreakdown {
                events.append(LedgerEvent(node: spec.id, by: .human("Alice"), kind: .gateOpened(.breakdown)))
            }
            try await ledger.append(events)
            self.audit = audit
            self.ledger = ledger
            self.local = local
            self.parentTicket = parent.key
            self.tracker = FailingTracker(base: LocalTrackerAdapter(tracker: local), failingTitle: failingTitle)
        }

        func makeReconciler() -> Reconciler {
            Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternalDependencies(),
                workspace: UnusedWorkspace(), artifacts: UnusedArtifacts(), checks: UnusedChecks(),
                team: AgentTeam(
                    name: "GH_27_1", decomposer: FixedDecomposer(),
                    testAuthor: UnusedTestAuthor(), implementer: UnusedImplementer()
                )
            )
        }

        func childTickets() async -> [Ticket] {
            await local.tickets().filter { $0.parentKey == parentTicket }
        }
    }

    private struct Creation: Sendable {
        let spec: NodeSpec
        let ticket: String
        let eventNode: NodeID?
        let ticketAtAppend: Ticket?
    }

    // Both persistence hooks share a lock so this observes ordering at the ledger write, not after a round.
    private final class AuditStore: LedgerStore, TicketStore {
        private struct State: Sendable {
            var records: [RecordedEvent] = []
            var tickets: [Ticket] = []
            var creations: [Creation] = []
        }

        private let state = Mutex(State())

        func loadAll() -> [RecordedEvent] { state.withLock { $0.records } }
        func load() -> [Ticket] { state.withLock { $0.tickets } }
        func save(_ tickets: [Ticket]) { state.withLock { $0.tickets = tickets } }

        func append(_ records: [RecordedEvent]) {
            state.withLock { value in
                for record in records {
                    if case .nodeCreated(let spec, let ticket) = record.event.kind,
                       spec.id != GH_27_1Tests.parentID {
                        value.creations.append(Creation(
                            spec: spec, ticket: ticket, eventNode: record.event.node,
                            ticketAtAppend: value.tickets.first { $0.key == ticket }
                        ))
                    }
                }
                value.records += records
            }
        }

        func childCreations() -> [Creation] { state.withLock { $0.creations } }
    }

    private actor FailingTracker: TrackerAdapter {
        let base: LocalTrackerAdapter
        private var failingTitle: String?
        private var attempts: [String] = []

        init(base: LocalTrackerAdapter, failingTitle: String?) {
            self.base = base
            self.failingTitle = failingTitle
        }

        func pendingSignals() async -> [Signal] { await base.pendingSignals() }
        func ticket(_ key: String) async -> Ticket? { await base.ticket(key) }
        func consume(_ signal: Signal, reply: String) async { await base.consume(signal, reply: reply) }
        func comment(on key: String, _ text: String) async { await base.comment(on: key, text) }
        func setStatus(of key: String, to status: String) async { await base.setStatus(of: key, to: status) }
        func close(_ key: String, saying text: String) async { await base.close(key, saying: text) }

        func createChildTicket(parent: String, spec: NodeSpec, by author: Participant) async throws -> String {
            attempts.append(spec.title)
            if spec.title == failingTitle {
                throw AgentFailure("GH_27_1 injected child-ticket creation failure")
            }
            return await base.createChildTicket(parent: parent, spec: spec, by: author)
        }

        func allowCreation() { failingTitle = nil }
        func creationAttempts() -> [String] { attempts }
    }

    private struct FixedDecomposer: Decomposer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            Breakdown(children: GH_27_1Tests.proposals)
        }
    }

    private struct NoExternalDependencies: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct UnusedWorkspace: Workspace {
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("GH_27_1-unused-\(id)")
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
            Issue.record("Breakdown must not perform workspace mutations or implementation checks")
            return AgentFailure("Unexpected workspace operation during GH_27_1 breakdown")
        }
    }

    private struct UnusedArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            Issue.record("Breakdown unexpectedly wrote an artifact")
            throw AgentFailure("Unexpected artifact during GH_27_1 breakdown")
        }
    }

    private struct UnusedChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("Breakdown unexpectedly ran implementation checks")
            return CheckOutput(passed: false, summary: "Unexpected check", log: "")
        }
    }

    private struct UnusedTestAuthor: TestAuthor {
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            Issue.record("Only parent breakdown should advance in these rounds")
            throw AgentFailure("Unexpected test author during GH_27_1 breakdown")
        }
    }

    private struct UnusedImplementer: Implementer {
        func implement(_ task: AgentTask) async throws {
            Issue.record("Breakdown unexpectedly started implementation")
            throw AgentFailure("Unexpected implementer during GH_27_1 breakdown")
        }
    }
}
