// API contract: Copilot role prompts honor Guesswork; Reconciler validates convention citations in
// AgentReport.assumptions, raises missing-path questions, and records valid assumptions in ledger and ticket output.

import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

@Suite
struct GH_30_3Tests {
    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func autonomousInstructionsAllowCitedRepositoryAnaloguesForUserVisibleDetails(
        role: AgentRole
    ) async throws {
        let prompt = try await capturePrompt(role: role, mode: .autonomous)
        let text = prompt.lowercased()

        #expect(text.contains("autonomous"))
        #expect(containsAny(text, ["user-visible", "user visible", "users will observe"]))
        #expect(containsAny(text, ["analog", "existing convention", "existing pattern"]))
        #expect(containsAny(text, ["landing branch", "landing-branch"]))
        #expect(text.contains("code"))
        #expect(text.contains("agents.md"))
        #expect(text.contains("design document"))
        #expect(text.contains("assumption"))
        #expect(containsAny(text, [
            "may decide", "can decide", "may resolve", "can resolve", "may choose", "can choose",
            "may assume", "can assume", "permit", "allowed", "use existing",
        ]))
        #expect(prompt.contains("<choice> (follows <path>: <symbol or section>)"))
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func autonomousInstructionsKeepQuestionsForScopeRiskConflictAndNovelty(
        role: AgentRole
    ) async throws {
        let text = try await capturePrompt(role: role, mode: .autonomous).lowercased()

        #expect(containsAny(text, ["ask", "question"]))
        #expect(containsAny(text, ["acceptance criterion", "acceptance-criterion", "acceptance criteria"]))
        #expect(containsAny(text, ["adding", "add behavior", "add behaviour"]))
        #expect(containsAny(text, ["dropping", "drop behavior", "drop behaviour", "removing"]))
        #expect(containsAny(text, ["narrowing", "narrow behavior", "narrow behaviour"]))
        #expect(containsAny(text, ["other work", "another work", "outside the ticket"]))
        #expect(text.contains("conflict"))
        #expect(containsAny(text, ["departure", "depart from", "deviat"]))
        for risk in ["security", "permission", "writ", "execut", "push", "delet"] {
            #expect(text.contains(risk), "Missing question boundary for \(risk).")
        }
        #expect(containsAny(text, ["new kinds", "new kind", "new types", "novel"]))
        #expect(containsAny(text, ["no analog", "without", "no repository", "no existing"]))
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func missingRepositoryPathsBecomeQuestionsAndStopAutonomousWork(
        role: AgentRole
    ) async throws {
        let malformed = [
            "Show newest entries first (follows existing convention: newestFirst)",
            "Show newest entries first (follows : newestFirst)",
            "Show newest entries first (follows the existing feed convention)",
        ]
        for assumption in malformed {
            let fixture = try await GH303Fixture(
                role: role, mode: .autonomous,
                report: AgentReport(assumptions: [assumption])
            )
            defer { fixture.cleanup() }

            let firstRound = await fixture.reconciler.runRound(waitForAgents: true)

            #expect(firstRound.safeStop == nil)
            let state = await fixture.ledger.workingState()
            let node = try #require(state.nodes[fixture.spec.id])
            #expect(state.status(of: node) == "Needs input")
            #expect(node.phase == .specified)
            #expect(node.testsDigest == nil)
            #expect(node.children.isEmpty)
            #expect(node.spec.kind == fixture.spec.kind)
            #expect(node.openQuestions.contains {
                $0.question.localizedCaseInsensitiveContains("newest entries first")
            })
            #expect(node.assumptions[role]?.contains(assumption) != true)
            #expect(!(await fixture.recordedAssumptions(role: role)).contains(assumption))
            let comments = await fixture.tracker.comments()
            #expect(comments.contains {
                $0.localizedCaseInsensitiveContains("newest entries first")
                    && $0.contains("harness:retry")
            })
            #expect(await fixture.tracker.status() == "Needs input")

            let secondRound = await fixture.reconciler.runRound(waitForAgents: true)
            #expect(secondRound.safeStop == nil)
            #expect(secondRound.isIdle)
            #expect(await fixture.reporter.calls(for: role) == 1,
                    "A missing citation must wait for human input, not silently rerun or proceed.")
        }
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func validConventionsAreLedgeredAndShownInTheExistingAssumptionSection(
        role: AgentRole
    ) async throws {
        for assumption in Self.validConventionAssumptions {
            let fixture = try await GH303Fixture(
                role: role, mode: .autonomous,
                report: AgentReport(assumptions: [assumption])
            )
            defer { fixture.cleanup() }

            let round = await fixture.reconciler.runRound(waitForAgents: true)

            #expect(round.safeStop == nil)
            let state = await fixture.ledger.workingState()
            let node = try #require(state.nodes[fixture.spec.id])
            #expect(node.openQuestions.isEmpty)
            #expect(node.flags[.needsInput] == nil)
            #expect(node.flags[.escalated] == nil)
            #expect(node.assumptions[role] == [assumption])
            #expect(await fixture.recordedAssumptions(role: role) == [assumption])
            let heading = role == .decomposer
                ? "Assumptions the decomposer made"
                : "Assumptions this work rests on"
            #expect(await fixture.tracker.comments().contains {
                $0.contains(heading) && $0.contains("- \(assumption)")
            })
            if role == .decomposer {
                #expect(node.spec.kind == .leaf)
            } else {
                #expect(node.phase == .ready)
                #expect(node.testsDigest != nil)
                #expect(state.status(of: node) == "Ready")
            }
        }
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func aValidCitationDoesNotHideAnotherAssumptionsMissingPath(role: AgentRole) async throws {
        let fixture = try await GH303Fixture(
            role: role, mode: .autonomous,
            report: AgentReport(assumptions: [
                Self.validConventionAssumptions[0],
                "Show newest entries first (follows the feed convention)",
            ])
        )
        defer { fixture.cleanup() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let state = await fixture.ledger.workingState()
        let node = try #require(state.nodes[fixture.spec.id])
        #expect(state.status(of: node) == "Needs input")
        #expect(node.openQuestions.contains {
            $0.question.localizedCaseInsensitiveContains("newest entries first")
        })
        #expect(node.phase == .specified)
        #expect(node.testsDigest == nil)
        #expect(node.spec.kind == fixture.spec.kind)
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func autonomousInternalAssumptionsDoNotNeedConventionCitations(role: AgentRole) async throws {
        let assumption = "Name the private helper buildRows"
        let fixture = try await GH303Fixture(
            role: role, mode: .autonomous,
            report: AgentReport(assumptions: [assumption])
        )
        defer { fixture.cleanup() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let node = try #require(await fixture.ledger.workingState().nodes[fixture.spec.id])
        #expect(node.openQuestions.isEmpty)
        #expect(node.flags[.needsInput] == nil)
        #expect(node.flags[.escalated] == nil)
        #expect(node.assumptions[role] == [assumption])
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func askModeStillTurnsEveryAssumptionIntoAQuestion(role: AgentRole) async throws {
        let assumptions = [
            "Name the private helper buildRows",
            Self.validConventionAssumptions[0],
        ]
        let question = AgentQuestion(question: "Which screen shows the feed?", suggestion: "Home")
        let fixture = try await GH303Fixture(
            role: role, mode: .ask,
            report: AgentReport(questions: [question], assumptions: assumptions)
        )
        defer { fixture.cleanup() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let state = await fixture.ledger.workingState()
        let node = try #require(state.nodes[fixture.spec.id])
        #expect(state.status(of: node) == "Needs input")
        #expect(node.openQuestions == [question] + assumptions.map { AgentQuestion(question: $0) })
        #expect(node.phase == .specified)
        #expect(node.testsDigest == nil)
        #expect(await fixture.recordedAssumptions(role: role).isEmpty)
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func assumeAndReportStillAsksQuestionsEvenWithSuggestedAnswers(role: AgentRole) async throws {
        let question = AgentQuestion(question: "Which screen shows the feed?", suggestion: "Home")
        let fixture = try await GH303Fixture(
            role: role, mode: .assumeAndReport,
            report: AgentReport(questions: [question])
        )
        defer { fixture.cleanup() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let state = await fixture.ledger.workingState()
        let node = try #require(state.nodes[fixture.spec.id])
        #expect(state.status(of: node) == "Needs input")
        #expect(node.openQuestions == [question])
        #expect(node.testsDigest == nil)
        #expect(node.spec.kind == fixture.spec.kind)
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func assumeAndReportKeepsUncitedAssumptionsAndTestReviewBehavior(role: AgentRole) async throws {
        let assumption = "Show newest entries first (follows the feed convention)"
        let fixture = try await GH303Fixture(
            role: role, mode: .assumeAndReport,
            report: AgentReport(assumptions: [assumption])
        )
        defer { fixture.cleanup() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let node = try #require(await fixture.ledger.workingState().nodes[fixture.spec.id])
        #expect(node.openQuestions.isEmpty)
        #expect(node.flags[.escalated] == nil)
        #expect(node.assumptions[role] == [assumption])
        #expect(await fixture.recordedAssumptions(role: role) == [assumption])
        #expect(await fixture.tracker.comments().contains { $0.contains(assumption) })
        if role == .testAuthor {
            #expect(node.phase == .ready)
            #expect(node.testsDigest != nil)
            #expect(node.flags[.needsInput] != nil)
            #expect(await fixture.tracker.comments().contains {
                $0.contains("Review the acceptance tests and assumptions")
                    || $0.contains("review the acceptance tests and assumptions")
            })
        } else {
            #expect(node.spec.kind == .leaf)
            #expect(node.flags[.needsInput] == nil)
        }
    }

    @Test(arguments: [AgentRole.decomposer, .testAuthor])
    func nonAutonomousInstructionsRetainTheirExistingQuestionAndAssumptionRules(
        role: AgentRole
    ) async throws {
        for mode in [Guesswork.ask, .assumeAndReport] {
            let prompt = try await capturePrompt(role: role, mode: mode)

            #expect(prompt.contains("Ask a question when the spec and answers don't settle what users will observe"))
            #expect(prompt.contains("Never guess that."))
            if mode == .ask {
                #expect(prompt.contains("Do not assume anything else either"))
            } else {
                #expect(prompt.contains("names, structure, details users don't see"))
                #expect(prompt.contains("list it as an assumption"))
            }
        }
    }

    private static let validConventionAssumptions = [
        "Show newest entries first (follows Sources/Feed/FeedView.swift: newestFirst)",
        "Show newest entries first (follows AGENTS.md: Feed ordering)",
        "Show newest entries first (follows docs/design.md: Feed ordering)",
    ]

    private func containsAny(_ text: String, _ alternatives: [String]) -> Bool {
        alternatives.contains { text.contains($0) }
    }

    private func capturePrompt(role: AgentRole, mode: Guesswork) async throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agentos-gh-30-3-prompt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = GH303Fixture.makeSpec(role: role)
        let context = AgentContext(designDocumentPaths: ["docs/design.md"])
        if role == .testAuthor {
            return CopilotTestAuthor.prompt(for: AgentTask(
                spec: spec, run: "gh-30-3-prompt", directory: root,
                testFolder: "Tests/GH_30_3Tests", scratchDirectory: root.appending(path: "scratch"),
                guesswork: mode, agentContext: context
            ))
        }

        let executable = root.appending(path: "fake-copilot")
        try """
            #!/bin/sh
            test "$1" = "-p" || exit 2
            printf '%s' "$2" > "$(dirname "$0")/captured-prompt.txt"
            printf '%s\\n' '{"questions":["Prompt capture only"],"children":[]}'
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let team = AgentTeam.copilot(CopilotCLI(executable: executable.path, timeout: .seconds(10)))
        _ = try await team.decomposer.proposeChildren(BreakdownRequest(
            spec: spec, guesswork: mode, codebase: root, agentContext: context
        ))
        return try String(contentsOf: root.appending(path: "captured-prompt.txt"), encoding: .utf8)
    }

    private struct GH303Fixture {
        let root: URL
        let spec: NodeSpec
        let ledger: Ledger
        let tracker: GH303Tracker
        let reporter: GH303Reporter
        let reconciler: Reconciler

        static func makeSpec(role: AgentRole) -> NodeSpec {
            NodeSpec(
                id: "wn-GH-30.3", parent: nil,
                kind: role == .decomposer ? .composite : .leaf,
                title: "Show the feed", intent: "Reuse repository feed ordering",
                acceptanceCriteria: ["Show feed entries in the established repository order"],
                touches: ["Feed"]
            )
        }

        init(role: AgentRole, mode: Guesswork, report: AgentReport) async throws {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "agentos-gh-30-3-state-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: root.appending(path: "Sources/Feed"), withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: root.appending(path: "docs"), withIntermediateDirectories: true
            )
            try "func newestFirst() {}\n".write(
                to: root.appending(path: "Sources/Feed/FeedView.swift"), atomically: true, encoding: .utf8
            )
            for path in ["AGENTS.md", "docs/design.md"] {
                try "# Feed ordering\nShow newest entries first.\n".write(
                    to: root.appending(path: path), atomically: true, encoding: .utf8
                )
            }
            let spec = Self.makeSpec(role: role)
            let ledger = try Ledger()
            try await ledger.append([
                LedgerEvent(
                    node: spec.id, by: .human("Alice"),
                    kind: .nodeCreated(spec: spec, ticket: "GH-30.3")
                ),
                LedgerEvent(node: spec.id, by: .human("Alice"), kind: .gateOpened(.breakdown)),
                LedgerEvent(node: spec.id, by: .human("Alice"), kind: .gateOpened(.build)),
            ])
            let tracker = GH303Tracker()
            let reporter = GH303Reporter(report: report)
            self.root = root
            self.spec = spec
            self.ledger = ledger
            self.tracker = tracker
            self.reporter = reporter
            self.reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: GH303External(),
                workspace: GH303Workspace(root: root), artifacts: GH303Artifacts(),
                checks: GH303Checks(),
                team: AgentTeam(
                    name: "GH-30.3 reports", decomposer: reporter, testAuthor: reporter,
                    implementer: GH303Implementer()
                ),
                policy: Policy(guesswork: mode)
            )
        }

        func recordedAssumptions(role: AgentRole) async -> [String] {
            await ledger.allRecords().flatMap { record -> [String] in
                guard record.event.node == spec.id,
                      case .assumptionsReported(let reportedRole, let assumptions) = record.event.kind,
                      reportedRole == role else { return [] }
                return assumptions
            }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private actor GH303Reporter: Decomposer, TestAuthor {
        let report: AgentReport
        private var counts: [AgentRole: Int] = [:]

        init(report: AgentReport) { self.report = report }

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            counts[.decomposer, default: 0] += 1
            return Breakdown(children: [
                ChildProposal(
                    title: request.spec.title,
                    acceptanceCriteria: request.spec.acceptanceCriteria,
                    touches: request.spec.touches
                ),
            ], report: report)
        }

        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            counts[.testAuthor, default: 0] += 1
            let folder = task.directory.appending(path: task.testFolder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try """
                import Testing
                @Suite struct FeedAcceptanceTests {
                    @Test func establishedOrdering() { #expect(true) }
                }
                """.write(to: folder.appending(path: "FeedAcceptanceTests.swift"), atomically: true, encoding: .utf8)
            return report
        }

        func calls(for role: AgentRole) -> Int { counts[role, default: 0] }
    }

    private actor GH303Tracker: TrackerAdapter {
        private var recordedComments: [String] = []
        private var recordedStatus: String?

        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? {
            Ticket(
                key: key, title: "Show the feed", description: "Reuse repository feed ordering",
                acceptanceCriteria: ["Show feed entries in the established repository order"],
                createdBy: .human("Alice")
            )
        }
        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("GH-30.3 fixture expects a single leaf, not child tickets")
        }
        func comment(on key: String, _ text: String) { recordedComments.append(text) }
        func setStatus(of key: String, to status: String) { recordedStatus = status }
        func comments() -> [String] { recordedComments }
        func status() -> String? { recordedStatus }
    }

    private struct GH303Workspace: Workspace {
        let root: URL
        var testArea: String { "Tests/" }
        var agentContext: String { "" }
        var designDocumentPaths: [String] { ["docs/design.md"] }
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { root }
        func createWorktree(for id: NodeID) async throws -> URL { root }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            "acceptance-tests"
        }
        func head(of directory: URL) async throws -> String { "acceptance-tests" }
        func changedFiles(in directory: URL) async throws -> [String] {
            ["Tests/GH_30_3Tests/FeedAcceptanceTests.swift"]
        }
        func testFolder(for spec: NodeSpec) -> String { "Tests/GH_30_3Tests" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed" }
        func existingComponents() -> [String] { ["Feed"] }
        func prepareBuild(in directory: URL) async throws {}
        func createSnapshot() async throws -> URL? { root }
    }

    private struct GH303Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    private struct GH303External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    private struct GH303Checks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "Fixture checks", log: "")
        }
    }

    private struct GH303Implementer: Implementer {
        func implement(_ task: AgentTask) async throws {
            throw AgentFailure("Implementation must not run while testing report handling")
        }
    }
}
