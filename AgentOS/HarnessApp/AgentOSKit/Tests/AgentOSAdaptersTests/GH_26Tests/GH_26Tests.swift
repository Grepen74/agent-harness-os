// API contract: Reconciler.runRound(waitForAgents: true) diagnoses landing failures in other suites by running the
// whole check again, then only the failing suites (CheckRunner.runChecks(only:)) with the change and on
// Workspace.createSnapshot(for:) (latest requirement branch, without the change). CheckRunner supplies named failures in
// CheckOutput.log; tracker comments expose every rerun's summary.

@testable import AgentOSCore
import AgentOSTestSupport
import Foundation
import Synchronization
import Testing

@Suite
struct GH_26Tests {
    @Test
    func otherProvenTicketsTestsAreCheckedOnLatestMainBeforeAConflictIsDeclared() async throws {
        let fixture = try await Fixture(retryPasses: false)
        defer { fixture.cleanUp() }

        let round = await fixture.reconciler.runRound(waitForAgents: true)

        #expect(round.safeStop == nil)
        let calls = await fixture.checks.calls
        let baseline = calls.filter { $0.directory == fixture.workspace.snapshot }
        #expect(!baseline.isEmpty, "A failure in another proven ticket is not itself proof of a conflict")
        for owner in Fixture.owners {
            #expect(baseline.contains { $0.selection == owner.testTarget },
                    "Rerun the failing tests of \(owner.testTarget) without the candidate")
        }
        for call in baseline {
            #expect(call.selection != nil, "Only the failing suites run on main, not every test")
            #expect(call.commit == Fixture.latestMain)
            #expect(call.commit != Fixture.previousMain)
        }
        for call in calls.dropFirst() {
            #expect(!call.alreadyEscalated, "Diagnose before recording a requirements conflict")
            #expect(call.failedAttempts == 0, "Diagnostic runs must precede attempt attribution")
        }
        #expect(await fixture.workspace.preparedDirectories.contains(fixture.workspace.snapshot))
    }

    @Test(arguments: [false, true])
    func failuresAlsoPresentOnMainAreReportedWithoutARequirementsConflictOrFailedAttempt(
        alonePasses: Bool
    ) async throws {
        let fixture = try await Fixture(retryPasses: false, alonePasses: alonePasses, mainPasses: false)
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let node = try #require(await fixture.node())
        #expect(node.failedAttempts == 0)
        #expect(node.flags[.escalated]?.lowercased().contains("requirements conflict") != true)
        #expect(await fixture.workspace.landedNodes.isEmpty)
        let comments = await fixture.tracker.comments(on: Fixture.ticket)
        let report = comments.joined(separator: "\n")
        #expect(report.contains("agentos/\(Fixture.ticket)"))
        #expect(!report.lowercased().contains("requirements conflict:"))
        for name in Fixture.failedTests {
            #expect(report.contains(name), "Name the failing test, not just its owning ticket")
        }
        for owner in Fixture.owners {
            let otherComments = await fixture.tracker.comments(on: String(owner.id.dropFirst(3)))
            #expect(!otherComments.contains { $0.contains("contradicts this ticket") })
        }
    }

    @Test
    func failingAloneWithTheChangeButNotOnMainEscalatesAsARequirementsConflict() async throws {
        let fixture = try await Fixture(retryPasses: false, alonePasses: false, mainPasses: true)
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let calls = await fixture.checks.calls
        #expect(calls.contains { $0.directory == fixture.workspace.snapshot })
        let candidate = calls.filter { $0.directory == fixture.workspace.candidate }
        #expect(candidate.filter { $0.selection == nil }.count == 2, "The whole check runs again first")
        let node = try #require(await fixture.node())
        let reason = try #require(node.flags[.escalated])
        #expect(reason.lowercased().contains("requirements conflict"))
        #expect(node.phase != .proven)
        #expect(await fixture.workspace.landedNodes.isEmpty)
        for owner in Fixture.owners {
            #expect(reason.contains(String(owner.id.dropFirst(3))))
        }
    }

    @Test
    func passingTheWholeCheckAgainReportsAnUnreliableTestAndLandsWithoutCountingAFailure() async throws {
        let fixture = try await Fixture(retryPasses: true)
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let node = try #require(await fixture.node())
        #expect(node.phase == .proven)
        #expect(node.landedCommit == Fixture.candidateCommit)
        #expect(node.flags[.escalated] == nil)
        #expect(node.failedAttempts == 0)
        #expect(await fixture.workspace.landedNodes == [Fixture.spec.id])
        #expect(await fixture.checks.calls.allSatisfy { $0.selection == nil },
                "Landing needs every check passing, not only the failing suites")
        let report = await fixture.tracker.comments(on: Fixture.ticket).joined(separator: "\n")
        #expect(report.lowercased().contains("unreliable"))
        for name in Fixture.failedTests {
            #expect(report.contains(name))
        }
        let state = await fixture.ledger.workingState()
        for owner in Fixture.owners {
            #expect(state.nodes[owner.id]?.phase == .proven)
            #expect(state.nodes[owner.id]?.landedCommit == Fixture.previousMain)
        }
    }

    @Test(arguments: [true, false])
    func failingTwiceInFullButPassingAloneIsEscalatedWithoutLandingOrCountingAFailure(selectsSuites: Bool) async throws {
        let fixture = try await Fixture(retryPasses: false, alonePasses: true, mainPasses: true, selectsSuites: selectsSuites,
                                        failingTestLogs: (
            initial: "✘ Test passingLandingRerunLands(_:) recorded an issue with 1 argument role → .implementer "
                + "at GH_19Tests.swift:78:9: Expectation failed: took 8.98 seconds",
            rerun: "✘ Test catchUpPreservesLandedWork() recorded an issue at GH_10Tests.swift:183:9: took 4.16 seconds"
        ))
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let node = try #require(await fixture.node())
        let reason = try #require(node.flags[.escalated])
        #expect(reason.contains("Unreliable tests or interference under load"))
        #expect(!reason.lowercased().contains("requirements conflict:"))
        #expect(reason.contains("GH_19Tests.passingLandingRerunLands"))
        #expect(reason.contains("GH_10Tests.catchUpPreservesLandedWork"))
        #expect(reason.contains(selectsSuites ? "rerun alone" : "so all tests"))
        #expect(reason.contains("with no other work running"))
        if selectsSuites {
            #expect(reason.contains(fixture.mainWhole.summary), "Main's own whole check decides it's not the change")
        }
        #expect(node.failedAttempts == 0)
        #expect(node.phase == .landing, "harness:retry checks the same change again")
        #expect(await fixture.workspace.landedNodes.isEmpty, "Passing alone doesn't rule out interference by the change")
        for owner in Fixture.owners {
            let otherComments = await fixture.tracker.comments(on: String(owner.id.dropFirst(3)))
            #expect(!otherComments.contains { $0.contains("contradicts this ticket") })
        }
        if !selectsSuites {
            #expect(await fixture.checks.calls.allSatisfy { $0.selection == nil })
        }
    }

    @Test
    func failuresOnlyInTheWholeCheckWhichPassesOnMainAreTheChangesOwnMistake() async throws {
        let fixture = try await Fixture(retryPasses: false, alonePasses: true, mainPasses: true, mainWholePasses: true)
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let node = try #require(await fixture.node())
        #expect(node.flags[.escalated] == nil, "The change disturbs the tests: rework, not a human")
        #expect(node.phase == .ready)
        #expect(await fixture.workspace.landedNodes.isEmpty)
        let report = await fixture.tracker.comments(on: Fixture.ticket).joined(separator: "\n")
        #expect(report.contains("own mistake"))
        #expect(report.contains("disturbs them"))
        #expect(report.contains(fixture.mainWhole.summary))
        #expect(await fixture.checks.calls.contains { $0.directory == fixture.workspace.snapshot && $0.selection == nil })
        for owner in Fixture.owners {
            let otherComments = await fixture.tracker.comments(on: String(owner.id.dropFirst(3)))
            #expect(!otherComments.contains { $0.contains("contradicts this ticket") })
        }
    }

    @Test
    func theWholeCheckRunsAgainOnlyAfterOtherWorkFinishesAndNothingStartsMeanwhile() async throws {
        let running = NodeSpec(
            id: "wn-GH-90", parent: nil, kind: .leaf, title: "Running", intent: "Busy", acceptanceCriteria: ["Busy"]
        )
        let waiting = NodeSpec(
            id: "wn-GH-91", parent: nil, kind: .leaf, title: "Waiting", intent: "Idle", acceptanceCriteria: ["Idle"]
        )
        let author = GatedTestAuthor(holding: running.id)
        let fixture = try await Fixture(
            retryPasses: true, otherNodes: [running, waiting], testAuthor: author, maxParallelAgents: 3
        )
        defer { fixture.cleanUp() }
        try await fixture.ledger.append([
            LedgerEvent(node: running.id, by: .human("Developer"), kind: .gateOpened(.build)),
        ])

        let round = Task { await fixture.reconciler.runRound() }
        try await author.started.wait(for: "\(running.id)'s test author starting")
        try await eventually("the landing waiting for other work") { await fixture.reconciler.quietLandings > 0 }
        try await fixture.ledger.append([
            LedgerEvent(node: waiting.id, by: .human("Developer"), kind: .gateOpened(.build)),
        ])
        _ = await fixture.reconciler.runRound()
        #expect(await author.authored == [running.id], "No step starts while the landing waits for quiet")
        #expect(await fixture.checks.calls.count == 1, "The whole check runs again only once other work finished")

        author.release.open()
        _ = try await withHangGuard("the landing round") { await round.value }
        try await withHangGuard("the other steps") { await fixture.reconciler.waitForAgents() }

        #expect(await fixture.checks.calls.count == 2)
        #expect(await fixture.node()?.phase == .proven)
        let report = await fixture.tracker.comments(on: Fixture.ticket).joined(separator: "\n")
        #expect(report.contains("with no other work running"))
    }

    @Test
    func infrastructureEscalationsAreRetriedByThemselvesAfterEachWaitUntilTheWaitsRunOut() async throws {
        let clock = FakeClock()
        let fixture = try await Fixture(retryPasses: false, alonePasses: true, mainPasses: true,
                                        retryDelays: [600, 1800], now: { clock.now })
        defer { fixture.cleanUp() }
        let retries = { await fixture.tracker.comments(on: Fixture.ticket).filter { $0.contains("Trying again by itself") } }

        _ = await fixture.reconciler.runRound(waitForAgents: true)
        #expect(await fixture.node()?.flags[.escalated]?.contains("Unreliable tests") == true)

        let escalatedAt = clock.now
        clock.advance(599)
        let waiting = await fixture.reconciler.runRound(waitForAgents: true)
        #expect(await retries().isEmpty, "Not before the first wait is over")
        #expect(waiting.retryDue == escalatedAt.addingTimeInterval(600), "So an unattended loop keeps going until then")
        let checksBeforeRetry = await fixture.checks.calls.count

        clock.advance(1)
        _ = await fixture.reconciler.runRound(waitForAgents: true)
        #expect(await retries().count == 1)
        #expect(await fixture.checks.calls.count > checksBeforeRetry, "The retry runs the landing check again")
        #expect(await fixture.node()?.flags[.escalated] != nil, "Failing again escalates again")

        clock.advance(1799)
        _ = await fixture.reconciler.runRound(waitForAgents: true)
        #expect(await retries().count == 1, "The second wait is longer, and counts from the new escalation")

        clock.advance(1)
        _ = await fixture.reconciler.runRound(waitForAgents: true)
        clock.advance(100_000)
        _ = await fixture.reconciler.runRound(waitForAgents: true)
        let node = try #require(await fixture.node())
        #expect(await retries().map { $0.contains("(2 of 2)") } == [false, true])
        #expect(node.flags[.escalated] != nil, "After the last wait it waits for a person")
        #expect(node.failedAttempts == 0)
        #expect(await fixture.workspace.landedNodes.isEmpty)
    }

    @Test
    func ownMistakesAreNeverRetriedByThemselves() async throws {
        let clock = FakeClock()
        let fixture = try await Fixture(retryPasses: false, alonePasses: false, mainPasses: true,
                                        retryDelays: [600], now: { clock.now })
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)
        let escalated = try #require(await fixture.node()?.flags[.escalated])
        #expect(escalated.contains("Requirements conflict"))
        clock.advance(100_000)
        _ = await fixture.reconciler.runRound(waitForAgents: true)

        #expect(await fixture.node()?.flags[.escalated] != nil)
        #expect(!(await fixture.tracker.comments(on: Fixture.ticket).contains { $0.contains("Trying again by itself") }))
    }

    @Test
    func aLandingBranchThatCantMoveHoldsLandingWithoutARunAndLandingGoesOnByItself() async throws {
        let fixture = try await Fixture(retryPasses: true, alonePasses: true, mainPasses: true)
        defer { fixture.cleanUp() }
        await fixture.workspace.scriptWaits([Fixture.checkedOut, Fixture.checkedOut])
        let waits = { await fixture.tracker.comments(on: Fixture.ticket).filter { $0.contains("Waiting to land") } }

        _ = await fixture.reconciler.runRound(waitForAgents: true)
        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let waiting = try #require(await fixture.node())
        #expect(waiting.phase == .landing)
        #expect(waiting.flags[.escalated] == nil)
        #expect(waiting.activeRun == nil)
        #expect(await fixture.checks.calls.isEmpty, "Nothing is checked while it can't land")
        #expect(await waits().count == 1, "The ticket hears about it once")
        #expect(await waits().first?.contains(Fixture.checkedOut) == true)

        _ = await fixture.reconciler.runRound(waitForAgents: true)
        #expect(await fixture.workspace.landedNodes == [Fixture.spec.id])
        #expect(await fixture.node()?.phase == .proven)
    }

    @Test
    func aLandingBranchCheckedOutDuringTheChecksWaitsInsteadOfFailing() async throws {
        let fixture = try await Fixture(retryPasses: true, alonePasses: true, mainPasses: true)
        defer { fixture.cleanUp() }
        await fixture.workspace.scriptWaits([nil, Fixture.checkedOut])

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let waiting = try #require(await fixture.node())
        #expect(!(await fixture.checks.calls.isEmpty))
        #expect(waiting.phase == .landing)
        #expect(waiting.flags[.escalated] == nil)
        #expect(waiting.activeRun == nil)
        #expect(waiting.failedAttempts == 0)
        #expect(await fixture.workspace.landedNodes.isEmpty)
        #expect(await fixture.tracker.comments(on: Fixture.ticket).contains { $0.contains("Waiting to land") })

        _ = await fixture.reconciler.runRound(waitForAgents: true)
        #expect(await fixture.workspace.landedNodes == [Fixture.spec.id])
    }

    @Test
    func aSelectionThatRunsNoTestIsAnInfrastructureProblemNotAPass() async throws {
        let fixture = try await Fixture(retryPasses: false, alonePasses: true, mainPasses: true, aloneRunsNothing: true)
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let node = try #require(await fixture.node())
        let reason = try #require(node.flags[.escalated])
        #expect(reason.contains("Landing infrastructure problem"))
        #expect(reason.contains("ran none of those tests"))
        #expect(node.failedAttempts == 0)
        #expect(await fixture.workspace.landedNodes.isEmpty)
    }

    @Test
    func aFailureInASuiteNoTicketOwnsIsDiagnosedInsteadOfBlamedOnTheChange() async throws {
        let fixture = try await Fixture(retryPasses: true, failingSuites: ["RepositoryWorkspaceTests"])
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let node = try #require(await fixture.node())
        #expect(node.phase == .proven)
        #expect(node.failedAttempts == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func everyDiagnosticReportNamesTheTestsAndEveryRerunOutcome(
        alonePasses: Bool, mainPasses: Bool
    ) async throws {
        let fixture = try await Fixture(retryPasses: false, alonePasses: alonePasses, mainPasses: mainPasses)
        defer { fixture.cleanUp() }

        _ = await fixture.reconciler.runRound(waitForAgents: true)

        let report = await fixture.tracker.comments(on: Fixture.ticket).joined(separator: "\n")
        for name in Fixture.failedTests {
            #expect(report.contains(name))
        }
        #expect(report.contains(fixture.retry.summary))
        for owner in Fixture.owners {
            #expect(report.contains(fixture.alone(owner.testTarget).summary))
            #expect(report.contains(fixture.onMain(owner.testTarget).summary))
        }
        #expect(!report.contains(" started."), "Only failure lines, not every test whose name mentions failing")
        let calls = await fixture.checks.calls
        #expect(calls.contains { $0.directory == fixture.workspace.snapshot })
    }
}

private extension GH_26Tests {
    struct Fixture {
        static let ticket = "GH-26"
        static let checkedOut = "agentos/main is checked out in /Users/someone/repo. Switch that checkout to another branch"
        static let previousMain = "previous-proven-agentos-main"
        static let latestMain = "latest-agentos-main"
        static let candidateCommit = "change-rebased-on-latest-agentos-main"
        static let spec = NodeSpec(
            id: "wn-GH-26", parent: nil, kind: .leaf, title: "Resize Changes",
            intent: "Resize a UI window", acceptanceCriteria: ["Changes can be resized"]
        )
        static let owners = [
            NodeSpec(
                id: "wn-GH-19", parent: nil, kind: .leaf, title: "Rerun landing",
                intent: "Rerun unchanged rework", acceptanceCriteria: ["Passing rework lands"]
            ),
            NodeSpec(
                id: "wn-GH-10", parent: nil, kind: .leaf, title: "Catch up main",
                intent: "Preserve landed work", acceptanceCriteria: ["Catch-up keeps landed work"]
            ),
        ]
        static let failedTests = [
            "GH_19Tests.passingLandingRerunLandsWithoutIncreasingFailedAttempts",
            "GH_10Tests.catchUpPreservesLandedWork",
        ]

        let root: URL
        let ledger: Ledger
        let tracker: RecordingTracker
        let workspace: RecordingWorkspace
        let checks: ScriptedChecks
        let reconciler: Reconciler
        let retry: CheckOutput
        let mainWhole: CheckOutput
        let aloneOutputs: [String: CheckOutput]
        let mainOutputs: [String: CheckOutput]

        /// The first full landing check fails in `failingSuites`; `retryPasses` is the whole check run again;
        /// `alonePasses` and `mainPasses` are the failing suites rerun alone with the change and on latest main;
        /// `mainWholePasses` is the whole check on latest main. `otherNodes` are leaves without gates.
        init(
            retryPasses: Bool, alonePasses: Bool = false, mainPasses: Bool = true, mainWholePasses: Bool = false,
            selectsSuites: Bool = true, aloneRunsNothing: Bool = false,
            failingSuites: Set<String> = Set(owners.map(\.testTarget)),
            failingTestLogs: (initial: String, rerun: String)? = nil, otherNodes: [NodeSpec] = [],
            testAuthor: any TestAuthor = UnusedAgents(), maxParallelAgents: Int = 1,
            retryDelays: [TimeInterval] = [], now: @escaping @Sendable () -> Date = { Date() }
        ) async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "agentos-GH-26-\(UUID().uuidString)")
            let candidate = root.appending(path: "candidate")
            let snapshot = root.appending(path: "latest-main-without-change")
            let folder = candidate.appending(path: "Tests/AgentOSAdaptersTests/GH_26Tests")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try "// fixed acceptance tests\n".write(
                to: folder.appending(path: "Acceptance.swift"), atomically: true, encoding: .utf8
            )
            ledger = try Ledger()
            for owner in Self.owners {
                try await ledger.append([
                    LedgerEvent(node: owner.id, by: .human("Developer"), kind: .nodeCreated(
                        spec: owner, ticket: String(owner.id.dropFirst(3))
                    )),
                    LedgerEvent(node: owner.id, by: .reconciler, kind: .landed(commit: Self.previousMain)),
                    LedgerEvent(node: owner.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
                ])
            }
            for other in otherNodes {
                try await ledger.append([
                    LedgerEvent(node: other.id, by: .human("Developer"), kind: .nodeCreated(
                        spec: other, ticket: String(other.id.dropFirst(3))
                    )),
                ])
            }
            try await ledger.append([
                LedgerEvent(node: Self.spec.id, by: .human("Developer"), kind: .nodeCreated(
                    spec: Self.spec, ticket: Self.ticket
                )),
                LedgerEvent(node: Self.spec.id, by: .human("Developer"), kind: .gateOpened(.build)),
                LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .testsFixed(
                    digest: Hashing.digest(of: folder)
                )),
                LedgerEvent(node: Self.spec.id, by: .agent(run: "builder", role: .implementer),
                            kind: .changeSubmitted(run: "builder", commit: Self.candidateCommit)),
                LedgerEvent(node: Self.spec.id, by: .reconciler, kind: .phaseChanged(to: .landing)),
            ])
            tracker = RecordingTracker()
            workspace = RecordingWorkspace(candidate: candidate, snapshot: snapshot)
            let suites = failingSuites.sorted()
            retry = Self.output(passed: retryPasses, context: "Whole check again", suites: suites, log: failingTestLogs?.rerun)
            var alone: [String: CheckOutput] = [:], onMain: [String: CheckOutput] = [:]
            for suite in selectsSuites ? suites : ["*"] {
                let only = suite == "*" ? suites : [suite]
                alone[suite] = Self.output(
                    passed: alonePasses, context: "\(suite) alone with the change", suites: only,
                    log: aloneRunsNothing ? "Test run with 0 tests passed." : nil
                )
                onMain[suite] = Self.output(passed: mainPasses, context: "\(suite) alone on agentos/\(Self.ticket)", suites: only)
            }
            aloneOutputs = alone
            mainOutputs = onMain
            mainWhole = Self.output(passed: mainWholePasses, context: "Whole check on agentos/main", suites: suites)
            checks = ScriptedChecks(
                workspace: workspace, ledger: ledger, selectsSuites: selectsSuites, mainWhole: mainWhole,
                initial: Self.output(passed: false, context: "Initial landing check", suites: suites,
                                     log: failingTestLogs?.initial),
                retry: retry, alone: alone, onMain: onMain
            )
            let unused = UnusedAgents()
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: unused, workspace: workspace,
                artifacts: MemoryArtifacts(), checks: checks,
                team: AgentTeam(name: "GH-26", decomposer: unused, testAuthor: testAuthor, implementer: unused),
                policy: {
                    var policy = Policy(maxParallelAgents: maxParallelAgents)
                    policy.landingBatchSize = 1
                    policy.infrastructureRetryDelays = retryDelays
                    return policy
                }(),
                now: now
            )
        }

        static func output(passed: Bool, context: String, suites: [String], log: String? = nil) -> CheckOutput {
            let result = passed ? "PASS" : "FAIL"
            let started = suites.map { "Test \($0).failingStorageWriteDoesNotPoison() started." }
            let tests = failedTests.filter { test in suites.contains { test.hasPrefix($0) } }
            return CheckOutput(
                passed: passed,
                summary: "\(context): \(result)",
                log: log ?? (started + (tests.isEmpty ? suites : tests).map { "\(result): \($0)" })
                    .joined(separator: "\n"),
                failingTargets: passed ? [] : Set(suites)
            )
        }

        func alone(_ suite: String) -> CheckOutput { aloneOutputs[suite]! }
        func onMain(_ suite: String) -> CheckOutput { mainOutputs[suite]! }

        func node() async -> NodeState? { await ledger.workingState().nodes[Self.spec.id] }

        func cleanUp() {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Could not remove GH-26 fixture directory: \(error)")
            }
        }
    }

    actor ScriptedChecks: CheckRunner {
        struct Call: Sendable {
            let directory: URL
            let selection: String?
            let commit: String
            let alreadyEscalated: Bool
            let failedAttempts: Int
        }

        let workspace: RecordingWorkspace
        let ledger: Ledger
        let initial: CheckOutput
        nonisolated let selectsSuites: Bool
        let retry: CheckOutput
        let mainWhole: CheckOutput
        let alone: [String: CheckOutput]
        let onMain: [String: CheckOutput]
        private var candidateCalls = 0
        private(set) var calls: [Call] = []

        init(
            workspace: RecordingWorkspace, ledger: Ledger, selectsSuites: Bool, mainWhole: CheckOutput,
            initial: CheckOutput, retry: CheckOutput, alone: [String: CheckOutput], onMain: [String: CheckOutput]
        ) {
            self.mainWhole = mainWhole
            self.workspace = workspace
            self.ledger = ledger
            self.selectsSuites = selectsSuites
            self.initial = initial
            self.retry = retry
            self.alone = alone
            self.onMain = onMain
        }

        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            let node = await ledger.workingState().nodes[Fixture.spec.id]
            let commit = await workspace.head(of: directory)
            calls.append(Call(
                directory: directory, selection: testTarget, commit: commit,
                alreadyEscalated: node?.flags[.escalated] != nil,
                failedAttempts: node?.failedAttempts ?? 0
            ))
            let scripted = directory == workspace.snapshot ? onMain : alone
            guard directory == workspace.snapshot || directory == workspace.candidate else {
                Issue.record("Unexpected diagnostic checkout: \(directory)")
                return CheckOutput(passed: false, summary: "Unexpected checkout", log: directory.path)
            }
            if directory == workspace.candidate && testTarget == nil {
                candidateCalls += 1
                if candidateCalls == 1 { return initial }
                if candidateCalls == 2 || selectsSuites { return retry }
            }
            if directory == workspace.snapshot && testTarget == nil && selectsSuites { return mainWhole }
            guard let output = scripted[testTarget ?? "*"] else {
                Issue.record("Unexpected selection \(testTarget ?? "all tests") in \(directory.lastPathComponent)")
                return CheckOutput(passed: false, summary: "Unexpected selection", log: "")
            }
            return output
        }
    }

    actor RecordingWorkspace: Workspace {
        nonisolated let candidate: URL
        nonisolated let snapshot: URL
        private(set) var preparedDirectories: [URL] = []
        private(set) var landedNodes: [NodeID] = []
        private var waits: [String?] = []

        init(candidate: URL, snapshot: URL) {
            self.candidate = candidate
            self.snapshot = snapshot
        }

        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { candidate }
        func createWorktree(for id: NodeID) async throws -> URL { candidate }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            Fixture.candidateCommit
        }
        func head(of directory: URL) -> String {
            directory == snapshot ? Fixture.latestMain : Fixture.candidateCommit
        }
        func changedFiles(in directory: URL) async throws -> [String] { ["App/Changes.swift"] }
        nonisolated var testArea: String { "Tests/AgentOSAdaptersTests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            landedNodes.append(id)
            return Fixture.candidateCommit
        }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws { preparedDirectories.append(directory) }
        func createSnapshot() async throws -> URL? { snapshot }
        func createSnapshot(for id: NodeID) async throws -> URL? { snapshot }
        func removeSnapshot(_ directory: URL) async {}
        /// The answers to `whyLandingMustWait`, one per question; nil once they run out.
        func scriptWaits(_ answers: [String?]) { waits = answers }
        func whyLandingMustWait(for id: NodeID) -> String? { waits.isEmpty ? nil : waits.removeFirst() }
    }

    actor RecordingTracker: TrackerAdapter {
        private var recorded: [String: [String]] = [:]
        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? {
            Ticket(
                key: key, title: key, description: key,
                acceptanceCriteria: ["Preserve proven behaviour"], createdBy: .human("Developer")
            )
        }
        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            Issue.record("Landing diagnostics must not create tickets")
            return "unexpected"
        }
        func comment(on key: String, _ text: String) { recorded[key, default: []].append(text) }
        func setStatus(of key: String, to status: String) {}
        func comments(on key: String) -> [String] { recorded[key, default: []] }
    }

    struct MemoryArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    /// A time the test moves on itself.
    final class FakeClock: Sendable {
        private let time = Mutex(Date(timeIntervalSinceReferenceDate: 800_000_000))
        var now: Date { time.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
    }

    /// Holds the test author of `held` until `release` opens, and records whose tests it was asked to write.
    actor GatedTestAuthor: TestAuthor {
        private enum Stopped: Error { case afterRelease }
        let held: NodeID
        nonisolated let started = TestGate()
        nonisolated let release = TestGate()
        private(set) var authored: [NodeID] = []

        init(holding held: NodeID) { self.held = held }

        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            authored.append(task.spec.id)
            if task.spec.id == held {
                started.open()
                try await release.wait()
            }
            throw Stopped.afterRelease
        }
    }

    struct UnusedAgents: ExternalDependencySource, Decomposer, TestAuthor, AgentOSCore.Implementer {
        private enum UnexpectedRun: Error { case agentDispatched }
        func deliveredKeys() async -> Set<String> { [] }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw UnexpectedRun.agentDispatched
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw UnexpectedRun.agentDispatched
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw UnexpectedRun.agentDispatched
        }
    }
}
