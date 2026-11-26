import AgentOSCore
import AgentOSTestSupport
import Foundation
import Synchronization
import Testing

extension GH_159Tests {
    static let spec = NodeSpec(
        id: "wn-GH-159-fixture", parent: nil, kind: .leaf, title: "Pre-check selected acceptance tests",
        intent: "Reject an empty test selection", acceptanceCriteria: ["Selected acceptance tests must run"]
    )

    enum Selection: CaseIterable, Sendable {
        case recorded, legacy

        var suite: String {
            switch self {
            case .recorded: "FeaturePrecheckTests"
            case .legacy: GH_159Tests.spec.testTarget
            }
        }
    }

    enum ZeroCounts: CaseIterable, Sendable {
        case swiftTesting, xctest, both

        struct Run: Sendable {
            let counts: ZeroCounts
            let successfulExit: Bool
        }

        static var runs: [Run] {
            allCases.flatMap { counts in
                [true, false].map { Run(counts: counts, successfulExit: $0) }
            }
        }

        var log: String {
            switch self {
            case .swiftTesting: "Test run with 0 tests passed after 0.001 seconds."
            case .xctest: "Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds."
            case .both: ZeroCounts.xctest.log + "\n" + ZeroCounts.swiftTesting.log
            }
        }
    }

    enum MixedCounts: CaseIterable, Sendable {
        case swiftOne, swiftMany, xctestOne, xctestMany

        var log: String {
            switch self {
            case .swiftOne: ZeroCounts.xctest.log + "\nTest run with 1 test passed."
            case .swiftMany: "Test run with 12 tests passed.\n" + ZeroCounts.xctest.log
            case .xctestOne: ZeroCounts.swiftTesting.log + "\nExecuted 1 test, with 0 failures."
            case .xctestMany: "Executed 12 tests, with 0 failures.\n" + ZeroCounts.swiftTesting.log
            }
        }
    }

    static func withFixture(
        selection: Selection, output: CheckOutput, maxAttempts: Int = 3,
        _ body: @escaping @Sendable (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await Fixture(selection: selection, output: output, maxAttempts: maxAttempts)
        do {
            try await withHangGuard("GH-159 pre-check scenario") { try await body(fixture) }
        } catch {
            await fixture.reconciler.shutdown(reason: "GH-159 fixture cleanup")
            try FileManager.default.removeItem(at: fixture.directory)
            throw error
        }
        await fixture.reconciler.shutdown(reason: "GH-159 fixture cleanup")
        try FileManager.default.removeItem(at: fixture.directory)
    }

    struct Fixture: Sendable {
        let directory: URL
        let selection: Selection
        let ledger: Ledger
        let checks: RecordingChecks
        let tracker = RecordingTracker()
        let artifacts = RecordingArtifacts()
        let reconciler: Reconciler

        init(selection: Selection, output: CheckOutput, maxAttempts: Int) async throws {
            self.selection = selection
            directory = FileManager.default.temporaryDirectory.appending(path: "GH_159Tests-\(UUID().uuidString)")
            let workspace = BranchWorkspace(directory: directory)
            let folder = workspace.testFolder(for: GH_159Tests.spec)
            let file = folder + "/Acceptance.swift"
            try FileManager.default.createDirectory(
                at: directory.appending(path: folder), withIntermediateDirectories: true
            )
            try Data("fixed acceptance tests".utf8).write(to: directory.appending(path: file))
            ledger = try Ledger()
            var kinds: [EventKind] = [.nodeCreated(spec: GH_159Tests.spec, ticket: "GH-159")]
            if selection == .recorded {
                kinds.append(.testsRecorded(files: [file], suite: selection.suite))
            }
            let digest = selection == .recorded
                ? Hashing.digest(ofRecordedFiles: [file], in: directory)
                : Hashing.digest(of: directory.appending(path: folder))
            kinds += [
                .testsFixed(digest: digest),
                .changeSubmitted(run: "implementer", commit: "candidate"),
                .phaseChanged(to: .checking),
            ]
            try await ledger.append(kinds.map {
                LedgerEvent(node: GH_159Tests.spec.id, by: .reconciler, kind: $0)
            })
            checks = RecordingChecks(output: output)
            let unused = UnusedServices()
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: unused, workspace: workspace,
                artifacts: artifacts, checks: checks,
                team: AgentTeam(name: "GH-159", decomposer: unused, testAuthor: unused, implementer: unused),
                policy: Policy(maxAttempts: maxAttempts, landingBatchSize: 1),
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            )
        }

        func precheck() async throws -> NodeState {
            let report = await reconciler.runRound(waitForAgents: true)
            #expect(report.safeStop == nil)
            #expect(!report.hasRunningAgents)
            let node = try #require(await ledger.workingState().nodes[GH_159Tests.spec.id])
            #expect(node.evidence.last?.check == "own acceptance tests on branch")
            return node
        }

        func expectSelectedBranch() async throws {
            let calls = await checks.calls
            try #require(!calls.isEmpty, "The fixture must actually reach the pre-check runner.")
            #expect(calls.allSatisfy { $0.suite == selection.suite && $0.directory == directory })
        }

        func expectOriginalOutcome(_ node: NodeState, output: CheckOutput) async throws {
            let evidence = try #require(node.evidence.last)
            #expect(evidence.passed == output.passed)
            #expect(evidence.summary == output.summary)
            #expect(artifacts.contents(at: evidence.artifactPath) == Data(output.log.utf8))
            #expect(node.phase == (output.passed ? .landing : .ready))
            #expect(node.failedAttempts == (output.passed ? 0 : 1))
            #expect(node.flags[.escalated] == nil)
        }
    }

    actor RecordingChecks: CheckRunner {
        struct Call: Sendable {
            let directory: URL
            let suite: String?
        }

        let output: CheckOutput
        private(set) var calls: [Call] = []

        init(output: CheckOutput) { self.output = output }

        func runChecks(in directory: URL, only testTarget: String?) -> CheckOutput {
            calls.append(Call(directory: directory, suite: testTarget))
            return output
        }
    }

    struct BranchWorkspace: Workspace {
        let directory: URL
        let testArea = "Tests/Acceptance/"
        let agentContext = ""

        func prepare() {}
        func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        func worktree(for id: NodeID) -> URL { directory }
        func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }
        func createWorktree(for id: NodeID) throws -> URL { throw AgentFailure("Unexpected test author") }
        func removeWorktree(for id: NodeID) throws { throw AgentFailure("Unexpected worktree removal") }
        func commitAll(in directory: URL, message: String, author: String) throws -> String? {
            throw AgentFailure("The submitted candidate is already committed.")
        }
        func head(of directory: URL) -> String { "candidate" }
        func changedFiles(in directory: URL) -> [String] { [testFolder(for: GH_159Tests.spec) + "/Acceptance.swift"] }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) {}
        func whyLandingMustWait(for id: NodeID) -> String? {
            "The fixture holds landing so the pre-check result can be observed."
        }
        func rebaseOntoMain(_ directory: URL) throws -> RebaseResult { throw AgentFailure("Unexpected landing") }
        func abortRebase(_ directory: URL) throws { throw AgentFailure("Unexpected rebase abort") }
        func resetForRework(_ directory: URL) throws { throw AgentFailure("Unexpected implementation rework") }
        func landOnMain(_ id: NodeID) throws -> String { throw AgentFailure("Unexpected landing") }
    }

    actor RecordingTracker: TrackerAdapter {
        private var messages: [String: [String]] = [:]
        private var statuses: [String: String] = [:]

        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("The leaf is already specified.")
        }
        func comment(on key: String, _ text: String) { messages[key, default: []].append(text) }
        func setStatus(of key: String, to status: String) { statuses[key] = status }
        func comments(on key: String) -> [String] { messages[key] ?? [] }
        func latestStatus(for key: String) -> String? { statuses[key] }
    }

    final class RecordingArtifacts: ArtifactStore, Sendable {
        private let logs = Mutex<[String: Data]>([:])

        func put(named name: String, contents: Data) -> StoredArtifact {
            logs.withLock { $0[name] = contents }
            return StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }

        func contents(at path: String) -> Data? { logs.withLock { $0[path] } }
    }

    struct UnusedServices: ExternalDependencySource, Decomposer, TestAuthor, AgentOSCore.Implementer {
        func deliveredKeys() -> Set<String> { [] }
        func proposeChildren(_ request: BreakdownRequest) throws -> Breakdown {
            throw AgentFailure("The leaf is already specified.")
        }
        func writeAcceptanceTests(_ task: AgentTask) throws -> AgentReport {
            throw AgentFailure("The acceptance tests are already fixed.")
        }
        func implement(_ task: AgentTask) throws -> AgentReport {
            throw AgentFailure("The implementation is already submitted.")
        }
    }
}
