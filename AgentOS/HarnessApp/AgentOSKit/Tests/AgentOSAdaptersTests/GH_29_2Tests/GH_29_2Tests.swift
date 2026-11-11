// API contract: agent reports carry expectedAPI and an optional brokenTest; AgentTask passes expectedAPI
// to implementers, and the reconciler routes broken-test reports without consuming implementation attempts.

import AgentOSCore
import AgentOSUI
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_29_2Tests {
    @Test
    func reportFileAcceptsBrokenTestAndImplementerReceivesExpectedAPI() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agentos-GH-29-2-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"""
            {
              "questions": [],
              "assumptions": [],
              "brokenTest": {
                "testName": "secondReportWaitsForAPerson",
                "reason": "The fixture cannot create the required prior report."
              }
            }
            """#.utf8).write(to: directory.appending(path: ".agentos-report.json"))

        let report = try AgentReportFile.take(from: directory)

        #expect(report.brokenTest?.testName == "secondReportWaitsForAPerson")
        #expect(report.brokenTest?.reason == "The fixture cannot create the required prior report.")

        let fixture = try await Fixture(
            implementerReports: [AgentReport()],
            expectedAPI: ["CheckOutput.runnerCrashed", "ProcessRunner.run(_:timeZone:)"]
        )
        await fixture.runRounds(2)

        #expect(await fixture.implementer.receivedExpectedAPI()
            == ["CheckOutput.runnerCrashed", "ProcessRunner.run(_:timeZone:)"])
    }

    @Test
    func firstBrokenTestReportIsRecordedAndSentBackWithoutChargingAnAttempt() async throws {
        let fixture = try await Fixture(implementerReports: [
            .init(brokenTest: .init(
                testName: "firstBrokenTestReportIsRecordedAndSentBackWithoutChargingAnAttempt",
                reason: "The test assumes a verifier result that the public API cannot produce."
            )),
        ])

        await fixture.runRounds(2)

        let node = try #require(await fixture.node())
        #expect(node.failedAttempts == 0)
        #expect(node.phase == .specified)

        let relevant = await fixture.routingEventSummaries()
        #expect(relevant.count == 2)

        await fixture.runRounds(1)
        #expect(await fixture.testAuthor.feedback().contains {
            $0.contains("public API cannot produce")
        })
    }

    @Test
    func reportOnTestsAlreadyReworkedForABrokenTestWaitsAndShowsBothReports() async throws {
        let fixture = try await Fixture(implementerReports: [
            .init(brokenTest: .init(testName: "originalContract", reason: "The original contract is impossible.")),
            .init(brokenTest: .init(testName: "rewrittenContract", reason: "The rewrite still requires hidden state.")),
        ])

        await fixture.runRounds(4)

        let node = try #require(await fixture.node())
        #expect(node.failedAttempts == 0)
        let reason = try #require(node.flags[.needsInput])
        #expect(reason.contains("originalContract"))
        #expect(reason.contains("The original contract is impossible."))
        #expect(reason.contains("rewrittenContract"))
        #expect(reason.contains("The rewrite still requires hidden state."))
        #expect(reason.localizedCaseInsensitiveContains("next"))
        #expect(await fixture.testAuthor.runCount() == 2)
    }

    @Test
    func compilationOnlyTestAuthorRewriteDoesNotMakeFirstBrokenReportWait() async throws {
        let fixture = try await Fixture(
            implementerReports: [
                .init(brokenTest: .init(
                    testName: "acceptanceTestsCompile",
                    reason: "The expected production symbol has the wrong signature."
                )),
            ],
            seedCompilationRewrite: true
        )

        await fixture.runRounds(1)

        let node = try #require(await fixture.node())
        #expect(node.failedAttempts == 0)
        #expect(node.flags[.needsInput] == nil)
        #expect(node.phase == .specified)
        #expect(await fixture.comments().contains {
            $0.contains("sent back to the test author")
        })
    }

    @Test
    func ticketCommentsNameTheTestReasonAndRoutingOutcome() async throws {
        let fixture = try await Fixture(implementerReports: [
            .init(brokenTest: .init(testName: "firstContract", reason: "It depends on private state.")),
            .init(brokenTest: .init(testName: "secondContract", reason: "It still depends on private state.")),
        ])

        await fixture.runRounds(2)
        #expect(await fixture.comments().contains {
            $0.contains("firstContract")
                && $0.contains("It depends on private state.")
                && $0.contains("sent back to the test author")
        })

        await fixture.runRounds(2)
        #expect(await fixture.comments().contains {
            $0.contains("secondContract")
                && $0.contains("It still depends on private state.")
                && $0.contains("waiting for a person: the test author already reworked these tests")
        })
    }

    @Test
    func workPaneModelsShowBrokenRunAndActionableAttention() async throws {
        let fixture = try await Fixture(implementerReports: [
            .init(brokenTest: .init(testName: "firstContract", reason: "The first API is unavailable.")),
            .init(brokenTest: .init(testName: "secondContract", reason: "The replacement API is also unavailable.")),
        ])
        await fixture.runRounds(4)

        let node = try #require(await fixture.node())
        let runs = AgentRuns.runs(of: node.id, in: await fixture.records())
        let implementerRuns = runs.filter { $0.role == .implementer }
        #expect(implementerRuns.map(\.outcome) == [
            "reported a broken test: firstContract",
            "reported a broken test: secondContract",
        ])

        let attention = try #require((await fixture.state()).attentionList.first {
            $0.node.id == node.id && $0.flag == .needsInput
        })
        #expect(attention.reason.contains("secondContract"))
        #expect(attention.reason.contains("The replacement API is also unavailable."))
        #expect(attention.reason.localizedCaseInsensitiveContains("next"))
    }
}

private extension GH_29_2Tests {
    final class Fixture: @unchecked Sendable {
        static let spec = NodeSpec(
            id: "wn-GH-29.2",
            parent: nil,
            kind: .leaf,
            title: "Route broken acceptance tests",
            intent: "Return broken tests to their author without charging the implementer",
            acceptanceCriteria: ["Broken tests are routed"]
        )

        let ledger: Ledger
        let tracker: RecordingTracker
        let testAuthor: RecordingTestAuthor
        let implementer: ScriptedImplementer
        let reconciler: Reconciler

        init(
            implementerReports: [AgentReport],
            expectedAPI: [String] = ["HarnessResult.brokenTest"],
            seedCompilationRewrite: Bool = false
        ) async throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "agentos-GH-29-2-\(UUID().uuidString)")
            let testFolder = directory.appending(path: "Tests/AgentOSAdaptersTests/GH_29_2Tests")
            try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
            try "// acceptance contract\n".write(
                to: testFolder.appending(path: "ContractTests.swift"),
                atomically: true,
                encoding: .utf8
            )

            ledger = try Ledger()
            tracker = RecordingTracker()
            testAuthor = RecordingTestAuthor(expectedAPI: expectedAPI)
            implementer = ScriptedImplementer(reports: implementerReports)

            var initial: [LedgerEvent] = [
                .init(node: Self.spec.id, by: .human("Alice"), kind: .nodeCreated(spec: Self.spec, ticket: "GH-29.2")),
                .init(node: Self.spec.id, by: .human("Alice"), kind: .gateOpened(.build)),
            ]
            if seedCompilationRewrite {
                initial += [
                    .init(node: Self.spec.id, by: .agent(run: "compile-fix-1", role: .testAuthor),
                          kind: .runStarted(run: "compile-fix-1", role: .testAuthor)),
                    .init(node: Self.spec.id, by: .agent(run: "compile-fix-1", role: .testAuthor),
                          kind: .runFinished(run: "compile-fix-1", outcome: "acceptance tests did not compile")),
                    .init(node: Self.spec.id, by: .reconciler, kind: .testsFixed(digest: Hashing.digest(of: testFolder))),
                    .init(node: Self.spec.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
                ]
            }
            try await ledger.append(initial)

            reconciler = Reconciler(
                ledger: ledger,
                tracker: tracker,
                external: NoExternalDependencies(),
                workspace: StubWorkspace(directory: directory),
                artifacts: MemoryArtifacts(),
                checks: PassingChecks(),
                team: AgentTeam(
                    name: "GH-29.2",
                    decomposer: NoopDecomposer(),
                    testAuthor: testAuthor,
                    implementer: implementer
                )
            )
        }

        func runRounds(_ count: Int) async {
            for _ in 0..<count {
                _ = await reconciler.runRound()
            }
        }

        func node() async -> NodeState? {
            await ledger.workingState().nodes[Self.spec.id]
        }

        func state() async -> WorkingState {
            await ledger.workingState()
        }

        func records() async -> [RecordedEvent] {
            await ledger.allRecords()
        }

        func routingEventSummaries() async -> [String] {
            await ledger.allRecords().compactMap { record in
                if case .runFinished = record.event.kind { return nil }
                let summary = record.event.kind.summary
                return summary.localizedCaseInsensitiveContains("broken test")
                    || summary.localizedCaseInsensitiveContains("sent back to the test author")
                    ? summary
                    : nil
            }
        }

        func comments() async -> [String] {
            await tracker.recordedComments()
        }
    }

    actor RecordingTestAuthor: TestAuthor {
        private let expectedAPI: [String]
        private var receivedFeedback: [String] = []
        private var count = 0

        init(expectedAPI: [String]) {
            self.expectedAPI = expectedAPI
        }

        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            count += 1
            if let previousFailure = task.previousFailure {
                receivedFeedback.append(previousFailure)
            }
            let test = task.directory.appending(path: "\(task.testFolder)/ContractTests.swift")
            try FileManager.default.createDirectory(
                at: test.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "// acceptance contract revision \(count)\n".write(to: test, atomically: true, encoding: .utf8)
            return AgentReport(expectedAPI: expectedAPI)
        }

        func feedback() -> [String] { receivedFeedback }
        func runCount() -> Int { count }
    }

    actor ScriptedImplementer: Implementer {
        private var reports: [AgentReport]
        private var expectedAPI: [String] = []

        init(reports: [AgentReport]) {
            self.reports = reports
        }

        func implement(_ task: AgentTask) async throws -> AgentReport {
            expectedAPI = task.expectedAPI
            return reports.isEmpty ? AgentReport() : reports.removeFirst()
        }

        func receivedExpectedAPI() -> [String] { expectedAPI }
    }

    actor RecordingTracker: TrackerAdapter {
        private var comments: [String] = []

        func pendingSignals() -> [Signal] { [] }

        func ticket(_ key: String) -> Ticket? {
            Ticket(
                key: key,
                title: "Route broken acceptance tests",
                description: "Return broken tests to their author",
                acceptanceCriteria: ["Broken tests are routed"],
                createdBy: .human("Alice")
            )
        }

        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String { "unused" }
        func comment(on key: String, _ text: String) { comments.append(text) }
        func setStatus(of key: String, to status: String) {}
        func recordedComments() -> [String] { comments }
    }

    struct StubWorkspace: Workspace {
        let directory: URL

        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory }
        func createWorktree(for id: NodeID) async throws -> URL { directory }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { "commit-\(author)" }
        func head(of directory: URL) async throws -> String { "head" }
        func changedFiles(in directory: URL) async throws -> [String] {
            ["Tests/AgentOSAdaptersTests/GH_29_2Tests/ContractTests.swift"]
        }
        var testArea: String { "Tests/AgentOSAdaptersTests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/AgentOSAdaptersTests/GH_29_2Tests" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { "landed" }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    struct PassingChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "passed", log: "passed")
        }
    }

    struct MemoryArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct NoExternalDependencies: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    struct NoopDecomposer: Decomposer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            Breakdown(children: [])
        }
    }
}
