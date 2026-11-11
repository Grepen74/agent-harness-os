// API contract: Reconciler.runRound() handles numbered suggested-answer corrections from human
// ticket comments plus harness:retry, records human-authored questionsAnswered events, and passes
// Clarification values to replacement BreakdownRequest/AgentTask runs through the existing protocols.

import AgentOSCore
import Foundation
import Testing
import AgentOSAdapters

@Suite
struct GH_30_5Tests {
    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func correctionIsTheCommentAuthorsClarificationAndReachesTheReplacement(role: AgentRole) async throws {
        let fixture = try await Fixture(role: role)
        try await fixture.advance()
        await fixture.tracker.correct("2: Show all matching results", author: "Bob", signalledBy: "Alice")

        try await fixture.advance(rounds: 4)

        let node = try #require(await fixture.node())
        let clarification = try #require(node.clarifications.first {
            $0.questions == [Fixture.questions[1].question]
                && $0.answer.contains("Show all matching results")
        })
        let recorded = await fixture.ledger.allRecords().filter {
            guard $0.event.node == Fixture.id,
                  case .questionsAnswered(let answer) = $0.event.kind else { return false }
            return answer == clarification
        }
        #expect(recorded.count == 1)
        #expect(recorded.first?.event.by == .human("Bob"))
        if role == .decomposer {
            let requests = await fixture.decomposer.requests()
            #expect(requests.count == 2)
            #expect(requests.last?.clarifications.contains(clarification) == true)
        } else {
            let tasks = await fixture.testAuthor.tasks(for: Fixture.id)
            #expect(tasks.count == 2)
            #expect(tasks.last?.clarifications.contains(clarification) == true)
            #expect(tasks.first?.run != tasks.last?.run)
        }
        #expect(await fixture.tracker.replies().contains {
            $0.hasPrefix("✅") && $0.contains("harness:retry")
        })
    }

    @Test
    func decompositionCorrectionRetainsUnchangedChildrenTheirTestsAndApprovals() async throws {
        let fixture = try await Fixture(role: .decomposer)
        try await fixture.advance(rounds: 2)
        let original = await fixture.ledger.workingState()
        let root = try #require(original.nodes[Fixture.id])
        let retainedID = try #require(root.children.first)
        let replacedID = try #require(root.children.last)
        let retained = try #require(original.nodes[retainedID])
        let replaced = try #require(original.nodes[replacedID])
        #expect(retained.phase == .ready)
        #expect(retained.testsDigest != nil)
        try await fixture.record(retainedID, [
            .gateOpened(.build),
            .flagSet(.needsInput, reason: "A person has paused this child before building"),
        ])
        let retainedTests = try Data(contentsOf: fixture.workspace.testsURL(for: retainedID))
        await fixture.tracker.correct("2: Show all matching results")

        try await fixture.advance(rounds: 4)

        let revised = await fixture.ledger.workingState()
        let newRoot = try #require(revised.nodes[Fixture.id])
        let kept = try #require(revised.nodes[retainedID])
        #expect(newRoot.phase == .split)
        #expect(newRoot.children.count == 2)
        #expect(newRoot.children.contains(retainedID))
        #expect(kept.ticket == retained.ticket)
        #expect(kept.testsDigest == retained.testsDigest)
        #expect(kept.phase == .ready)
        #expect(kept.gates.contains(.build))
        #expect(try Data(contentsOf: fixture.workspace.testsURL(for: retainedID)) == retainedTests)
        #expect(await fixture.testAuthor.tasks(for: retainedID).count == 1)
        #expect(revised.nodes.values.allSatisfy { $0.ticket != replaced.ticket })
        #expect(await fixture.tracker.closedTickets().contains(replaced.ticket))
        let newChild = try #require(newRoot.children.compactMap { revised.nodes[$0] }.first {
            $0.id != retainedID
        })
        #expect(newChild.spec.title == "Corrected results")
        #expect(newChild.ticket != replaced.ticket)
        #expect(await fixture.decomposer.requests().count == 2)
    }

    @Test(arguments: [Phase.ready, .checking, .landing])
    func testAuthorCorrectionDiscardsTheOldCopyAndRestartsFromLatestLandingBranch(phase: Phase) async throws {
        let fixture = try await Fixture(role: .testAuthor)
        try await fixture.advance()
        let original = try #require(await fixture.node())
        let firstTask = try #require(await fixture.testAuthor.tasks(for: Fixture.id).first)
        let staleFile = firstTask.directory.appending(path: "obsolete-implementation.txt")
        try "Must not survive correction".write(to: staleFile, atomically: true, encoding: .utf8)
        if phase != .ready {
            try await fixture.record(Fixture.id, [
                .changeSubmitted(run: "old-implementer", commit: "old-candidate"),
                .phaseChanged(to: phase),
            ])
        }
        await fixture.workspace.moveLandingBranch(to: "latest-landing")
        await fixture.tracker.correct("2: Show all matching results")

        try await fixture.advance(rounds: 4)

        let tasks = await fixture.testAuthor.tasks(for: Fixture.id)
        #expect(tasks.count == 2)
        let replacement = try #require(tasks.last)
        #expect(replacement.run != firstTask.run)
        let observations = await fixture.testAuthor.observations(for: Fixture.id)
        #expect(observations.last?.landingRevision == "latest-landing")
        #expect(observations.last?.foundObsoleteImplementation == false)
        #expect(observations.last?.foundOldTests == false)
        #expect(!FileManager.default.fileExists(atPath: staleFile.path))
        #expect(await fixture.workspace.operations() == [
            "create:\(Fixture.id):initial-landing",
            "remove:\(Fixture.id)",
            "create:\(Fixture.id):latest-landing",
        ])
        let replacementNode = try #require(await fixture.node())
        #expect(replacementNode.phase == .ready)
        #expect(replacementNode.lastSubmission == nil)
        #expect(replacementNode.testsDigest != original.testsDigest)
        #expect(replacementNode.landedCommit == nil)
        #expect(await fixture.workspace.landingCount() == 0)
    }

    @Test(arguments: [Phase.building, .checking, .landing, .proven])
    func decomposerCorrectionAfterAChildStartsBuildingIsRejectedAndLinksFollowUpWork(phase: Phase) async throws {
        let fixture = try await Fixture(role: .decomposer)
        try await fixture.advance(rounds: 2)
        let root = try #require(await fixture.node())
        let childID = try #require(root.children.first)
        var kinds: [EventKind] = [
            .phaseChanged(to: phase),
            .flagSet(.escalated, reason: "Hold the existing work while the correction is processed"),
        ]
        if phase == .proven { kinds.append(.landed(commit: "already-landed-child")) }
        try await fixture.record(childID, kinds)
        let before = await fixture.ledger.workingState()
        let affected = try #require(before.nodes[childID])
        let requestsBefore = await fixture.decomposer.requests().count
        let operationsBefore = await fixture.workspace.operations()
        await fixture.tracker.correct("2: Show all matching results")

        try await fixture.advance()

        let after = await fixture.ledger.workingState()
        let unchangedRoot = try #require(after.nodes[Fixture.id])
        #expect(unchangedRoot.spec == root.spec)
        #expect(unchangedRoot.children == root.children)
        #expect(unchangedRoot.phase == root.phase)
        #expect(unchangedRoot.clarifications == root.clarifications)
        #expect(unchangedRoot.assumptions == root.assumptions)
        #expect(after.nodes[childID]?.phase == affected.phase)
        #expect(after.nodes[childID]?.landedCommit == affected.landedCommit)
        #expect(await fixture.decomposer.requests().count == requestsBefore)
        #expect(await fixture.workspace.operations() == operationsBefore)
        let response = try #require(await fixture.tracker.replies().last)
        #expect(response.hasPrefix("❌"))
        #expect(response.localizedCaseInsensitiveContains("open"))
        #expect(response.localizedCaseInsensitiveContains("follow-up"))
        #expect(response.localizedCaseInsensitiveContains("ticket"))
        #expect(Self.hasWorkLink(response, ticket: affected.ticket, node: childID))
    }

    @Test
    func testAuthorCorrectionAfterLandingPreservesLandedWorkAndLinksFollowUpWork() async throws {
        let fixture = try await Fixture(role: .testAuthor)
        try await fixture.advance()
        try await fixture.record(Fixture.id, [
            .landed(commit: "immutable-landed-commit"),
            .phaseChanged(to: .proven),
        ])
        let before = try #require(await fixture.node())
        let testsBefore = try Data(contentsOf: fixture.workspace.testsURL(for: Fixture.id))
        let operationsBefore = await fixture.workspace.operations()
        await fixture.tracker.correct("2: Show all matching results")

        try await fixture.advance()

        let after = try #require(await fixture.node())
        #expect(after.landedCommit == "immutable-landed-commit")
        #expect(after.phase == .proven)
        #expect(after.spec == before.spec)
        #expect(after.testsDigest == before.testsDigest)
        #expect(after.clarifications == before.clarifications)
        #expect(after.assumptions == before.assumptions)
        #expect(try Data(contentsOf: fixture.workspace.testsURL(for: Fixture.id)) == testsBefore)
        #expect(await fixture.testAuthor.tasks(for: Fixture.id).count == 1)
        #expect(await fixture.workspace.operations() == operationsBefore)
        let response = try #require(await fixture.tracker.replies().last)
        #expect(response.hasPrefix("❌"))
        #expect(response.localizedCaseInsensitiveContains("open"))
        #expect(response.localizedCaseInsensitiveContains("follow-up"))
        #expect(response.localizedCaseInsensitiveContains("ticket"))
        #expect(Self.hasWorkLink(response, ticket: before.ticket, node: before.id))
    }

    @Test(
        arguments: [AgentRole.decomposer, .testAuthor],
        ["0: Different answer", "3: Different answer", "Use a different answer", "2:   "]
    )
    func invalidSuggestionReferencesDoNotRecordAnswersOrRestartWork(
        role: AgentRole, comment: String
    ) async throws {
        let fixture = try await Fixture(role: role)
        try await fixture.advance(rounds: 2)
        let before = try #require(await fixture.node())
        let decompositions = await fixture.decomposer.requests().count
        let authorings = await fixture.testAuthor.allTasks().count
        let operations = await fixture.workspace.operations()
        let recordCount = await fixture.ledger.allRecords().count
        await fixture.tracker.correct(comment)

        try await fixture.advance()

        let after = try #require(await fixture.node())
        #expect(after.clarifications == before.clarifications)
        #expect(after.assumptions == before.assumptions)
        #expect(after.children == before.children)
        #expect(after.phase == before.phase)
        #expect(after.testsDigest == before.testsDigest)
        #expect(await fixture.decomposer.requests().count == decompositions)
        #expect(await fixture.testAuthor.allTasks().count == authorings)
        #expect(await fixture.workspace.operations() == operations)
        let newRecords = await fixture.ledger.allRecords().dropFirst(recordCount)
        #expect(!newRecords.contains {
            if case .questionsAnswered = $0.event.kind { return true }
            return false
        })
        let response = try #require(await fixture.tracker.replies().last)
        #expect(response.hasPrefix("❌"))
        #expect(response.localizedCaseInsensitiveContains("suggest"))
        #expect(response.localizedCaseInsensitiveContains("number"))
        #expect(response.contains("harness:retry"))
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func anOldSuggestionNumberCannotCorrectAReplacementRunWithNoSuggestions(role: AgentRole) async throws {
        let fixture = try await Fixture(role: role)
        try await fixture.advance()
        await fixture.tracker.correct("2: Show all matching results")
        try await fixture.advance(rounds: 4)
        let before = try #require(await fixture.node())
        #expect(before.clarifications.count == 1)
        let decompositions = await fixture.decomposer.requests().count
        let authorings = await fixture.testAuthor.allTasks().count
        let operations = await fixture.workspace.operations()
        await fixture.tracker.correct("2: A stale correction")

        try await fixture.advance()

        #expect(await fixture.node()?.clarifications == before.clarifications)
        #expect(await fixture.decomposer.requests().count == decompositions)
        #expect(await fixture.testAuthor.allTasks().count == authorings)
        #expect(await fixture.workspace.operations() == operations)
        let response = try #require(await fixture.tracker.replies().last)
        #expect(response.hasPrefix("❌"))
        #expect(response.localizedCaseInsensitiveContains("suggest"))
        #expect(response.localizedCaseInsensitiveContains("number"))
        #expect(response.contains("harness:retry"))
    }

    private static func hasWorkLink(_ response: String, ticket: String, node: NodeID) -> Bool {
        let expression = #/\[[^\]]+\]\([^)]+\)/#
        return response.matches(of: expression).contains {
            $0.output.contains(ticket) || $0.output.contains(node)
        }
    }

    private final class Fixture: Sendable {
        static let id = "wn-GH-305"
        static let questions = [
            AgentQuestion(question: "Which layout should results use?", suggestion: "Use compact rows"),
            AgentQuestion(question: "How many results should appear?", suggestion: "Show ten results"),
        ]

        let directory: URL
        let ledger: Ledger
        let tracker: CorrectionTracker
        let workspace: CorrectionWorkspace
        let decomposer: CorrectionDecomposer
        let testAuthor: CorrectionTestAuthor
        let reconciler: Reconciler

        init(role: AgentRole) async throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "agentos-GH-30-5-\(UUID().uuidString)")
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ledger = try Ledger()
            tracker = CorrectionTracker(ticket: Ticket(
                key: "GH-305",
                title: "Correct suggested answers",
                description: "Redo affected work without losing unchanged children",
                acceptanceCriteria: ["Corrections reach the replacement agent"],
                createdBy: .human("Alice")
            ))
            workspace = CorrectionWorkspace(root: directory)
            decomposer = CorrectionDecomposer(suggests: role == .decomposer)
            testAuthor = CorrectionTestAuthor(suggests: role == .testAuthor)
            reconciler = Reconciler(
                ledger: ledger,
                tracker: tracker,
                external: NoExternalDependencies(),
                workspace: workspace,
                artifacts: MemoryArtifacts(),
                checks: PassingChecks(),
                team: AgentTeam(
                    name: "Correction acceptance tests",
                    decomposer: decomposer,
                    testAuthor: testAuthor,
                    implementer: UnexpectedImplementer()
                ),
                policy: Policy(guesswork: .autonomous)
            )
            let spec = NodeSpec(
                id: Self.id, parent: nil, kind: role == .decomposer ? .composite : .leaf,
                title: "Correct suggested answers",
                intent: "Redo affected work without losing unchanged children",
                acceptanceCriteria: ["Corrections reach the replacement agent"],
                touches: ["Results"]
            )
            try await ledger.append([
                LedgerEvent(node: Self.id, by: .human("Alice"), kind: .nodeCreated(spec: spec, ticket: "GH-305")),
                LedgerEvent(node: Self.id, by: .human("Alice"), kind: .gateOpened(.breakdown)),
            ])
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func advance(rounds: Int = 1) async throws {
            for _ in 0..<rounds {
                let report = await reconciler.runRound()
                #expect(report.safeStop == nil)
            }
        }

        func node() async -> NodeState? {
            await ledger.workingState().nodes[Self.id]
        }

        func record(_ id: NodeID, _ kinds: [EventKind]) async throws {
            try await ledger.append(kinds.map { LedgerEvent(node: id, by: .human("Alice"), kind: $0) })
        }
    }

    private actor CorrectionTracker: TrackerAdapter {
        nonisolated var contextRepository: String { "Grepen74/agent-harness-os" }
        private var tickets: [String: Ticket]
        private var signal: Signal?
        private var consumedReplies: [String] = []
        private var closed: [String] = []
        private var childNumber = 305

        init(ticket: Ticket) { tickets = [ticket.key: ticket] }

        func correct(_ text: String, author: String = "Alice", signalledBy: String = "Alice") {
            tickets["GH-305"]?.comments.append(Comment(author: .human(author), text: text))
            signal = Signal(ticket: "GH-305", command: .retry, setBy: .human(signalledBy))
        }

        func pendingSignals() -> [Signal] { signal.map { [$0] } ?? [] }
        func ticket(_ key: String) -> Ticket? { tickets[key] }
        func contextTickets() -> [Ticket] { Array(tickets.values) }
        func replies() -> [String] { consumedReplies }
        func closedTickets() -> [String] { closed }

        func consume(_ signal: Signal, reply: String) {
            self.signal = nil
            consumedReplies.append(reply)
            tickets[signal.ticket]?.comments.append(Comment(author: .reconciler, text: reply))
        }

        func comment(on key: String, _ text: String) {
            tickets[key]?.comments.append(Comment(author: .reconciler, text: text))
        }

        func setStatus(of key: String, to status: String) { tickets[key]?.status = status }

        func close(_ key: String, saying text: String) {
            closed.append(key)
            comment(on: key, text)
            setStatus(of: key, to: "Superseded")
        }

        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            childNumber += 1
            let key = "GH-\(childNumber)"
            tickets[key] = Ticket(
                key: key, title: spec.title, description: spec.intent,
                acceptanceCriteria: spec.acceptanceCriteria, parentKey: parent, createdBy: by
            )
            return key
        }
    }

    private actor CorrectionDecomposer: Decomposer {
        let suggests: Bool
        private var received: [BreakdownRequest] = []

        init(suggests: Bool) { self.suggests = suggests }
        func requests() -> [BreakdownRequest] { received }

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            received.append(request)
            return Breakdown(
                children: [
                    ChildProposal(title: "Unchanged layout", acceptanceCriteria: ["Compact rows"], touches: ["Results"]),
                    ChildProposal(
                        title: received.count == 1 ? "Original results" : "Corrected results",
                        acceptanceCriteria: [received.count == 1 ? "Ten results" : "All matching results"],
                        touches: ["Results"]
                    ),
                ],
                report: AgentReport(questions: suggests && received.count == 1 ? Fixture.questions : [])
            )
        }
    }

    private struct AuthorObservation: Sendable {
        let node: NodeID
        let landingRevision: String
        let foundObsoleteImplementation: Bool
        let foundOldTests: Bool
    }

    private actor CorrectionTestAuthor: TestAuthor {
        let suggests: Bool
        private var received: [AgentTask] = []
        private var observed: [AuthorObservation] = []

        init(suggests: Bool) { self.suggests = suggests }
        func allTasks() -> [AgentTask] { received }
        func tasks(for id: NodeID) -> [AgentTask] { received.filter { $0.spec.id == id } }
        func observations(for id: NodeID) -> [AuthorObservation] { observed.filter { $0.node == id } }

        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            let file = task.directory.appending(path: task.testFolder).appending(path: "Acceptance.swift")
            observed.append(AuthorObservation(
                node: task.spec.id,
                landingRevision: try String(contentsOf: task.directory.appending(path: "landing.txt"), encoding: .utf8),
                foundObsoleteImplementation: FileManager.default.fileExists(
                    atPath: task.directory.appending(path: "obsolete-implementation.txt").path
                ),
                foundOldTests: FileManager.default.fileExists(atPath: file.path)
            ))
            received.append(task)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let name = task.run.replacingOccurrences(of: "-", with: "_")
            try "import Testing\n@Test func acceptance_\(name)() { #expect(true) }\n"
                .write(to: file, atomically: true, encoding: .utf8)
            return AgentReport(questions: suggests && received.count == 1 ? Fixture.questions : [])
        }
    }

    private actor CorrectionWorkspace: Workspace {
        nonisolated let root: URL
        private var revision = "initial-landing"
        private var calls: [String] = []
        private var landings = 0

        init(root: URL) { self.root = root }
        func moveLandingBranch(to revision: String) { self.revision = revision }
        func operations() -> [String] { calls }
        func landingCount() -> Int { landings }
        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        nonisolated var testArea: String { "Tests/" }
        nonisolated var agentContext: String { "" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.id)" }
        nonisolated func testsURL(for id: NodeID) -> URL {
            worktree(for: id).appending(path: "Tests/\(id)/Acceptance.swift")
        }

        func createWorktree(for id: NodeID) async throws -> URL {
            calls.append("create:\(id):\(revision)")
            let directory = worktree(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try revision.write(to: directory.appending(path: "landing.txt"), atomically: true, encoding: .utf8)
            return directory
        }

        func removeWorktree(for id: NodeID) async throws {
            calls.append("remove:\(id)")
            let directory = worktree(for: id)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }

        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            "commit-\(author)"
        }
        func head(of directory: URL) async throws -> String { revision }
        func changedFiles(in directory: URL) async throws -> [String] {
            ["Tests/\(directory.lastPathComponent)/Acceptance.swift"]
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {
            throw AgentFailure("Correction must discard all old work, not preserve its acceptance tests")
        }
        func landOnMain(_ id: NodeID) async throws -> String {
            landings += 1
            return "landed-\(id)"
        }
        nonisolated func existingComponents() -> [String] { ["Results"] }
        func prepareBuild(in directory: URL) async throws {}
    }

    private struct NoExternalDependencies: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct MemoryArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    private struct PassingChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "Passed", log: "Passed")
        }
    }

    private struct UnexpectedImplementer: Implementer {
        func implement(_ task: AgentTask) async throws {
            throw AgentFailure("No test in this suite approves starting an implementation")
        }
    }
}
