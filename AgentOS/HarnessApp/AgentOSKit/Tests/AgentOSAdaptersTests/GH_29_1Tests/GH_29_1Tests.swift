// API contract: AgentReport declares expectedAPI; SwiftAcceptanceTestPreflight classifies compiler diagnostics;
// Reconciler accepts an AcceptanceTestPreflight and routes test-author failures before starting an implementer.

import Foundation
import Testing
@testable import AgentOSAdapters
import AgentOSCore

@Suite
struct GH_29_1Tests {
    @Test
    func swiftRepositoriesBuildTestsBeforeTheImplementerAndUnsupportedRepositoriesSkipPreflight() async throws {
        #expect(SwiftAcceptanceTestPreflight.command == ["swift", "build", "--build-tests"])

        let supported = try await Fixture(preflight: .init(outcomes: [.compiled]))
        _ = await supported.reconciler.runRound()
        #expect(await supported.preflight.invocationCount == 1)
        #expect(await supported.implementer.tasks.isEmpty)

        _ = await supported.reconciler.runRound()
        #expect(await supported.implementer.tasks.count == 1)
        #expect(await supported.preflight.invocationCount == 1)

        let unsupported = try await Fixture(preflight: .init(outcomes: [.skipped]))
        _ = await unsupported.reconciler.runRound()
        _ = await unsupported.reconciler.runRound()
        #expect(await unsupported.implementer.tasks.count == 1)
    }

    @Test
    func expectedAPIIsRecordedAndMissingProductionAPIDiagnosticsAreExpected() throws {
        let report = AgentReport(
            assumptions: ["The API belongs to the process adapter"],
            expectedAPI: ["CheckOutput.runnerCrashed", "ProcessRunner.run(_:timeZone:)"]
        )
        let decoded = try JSONDecoder().decode(AgentReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.expectedAPI == report.expectedAPI)

        let fixture = try ClassificationFixture()
        let messages = [
            "\(fixture.testFile.path):8:9: error: cannot find 'NewRunner' in scope",
            "\(fixture.testFile.path):9:18: error: cannot find type 'NewOutput' in scope",
            "\(fixture.testFile.path):10:25: error: value of type 'CheckOutput' has no member 'runnerCrashed'",
            "\(fixture.testFile.path):11:12: error: type 'ProcessRunner' has no member 'run'",
            "\(fixture.testFile.path):12:8: error: no such module 'FutureSupport'",
            "\(fixture.testFile.path):13:44: error: missing argument label 'timeZone:' in call",
            "\(fixture.testFile.path):14:19: error: no exact matches in call to initializer",
            "\(fixture.testFile.path):15:18: error: cannot find type 'UnlistedFutureType' in scope",
        ].joined(separator: "\n")

        let result = SwiftAcceptanceTestPreflight.classify(
            log: messages,
            in: fixture.root,
            testFolder: fixture.testFolder,
            expectedAPI: report.expectedAPI + ["NewRunner", "NewOutput", "FutureSupport"]
        )

        #expect(result.diagnostics.count == 8)
        #expect(result.diagnostics.allSatisfy { $0.classification == .expected })
        #expect(result.testAuthorMistakes.isEmpty)
    }

    @Test
    func testSymbolsSyntaxAndWrongExistingProductionAPIsAreAuthorMistakesWhileUnknownDiagnosticsAreExpected() throws {
        let fixture = try ClassificationFixture()
        let messages = [
            "\(fixture.testFile.path):20:15: error: static member 'repeatedCrashLog' cannot be used on instance of type 'GH_29_1Tests'",
            "\(fixture.testFile.path):21:9: error: expected expression after operator",
            "\(fixture.testFile.path):22:25: error: value of type 'ExistingService' has no member 'rn'",
            "\(fixture.testFile.path):23:9: error: the compiler was unable to type-check this expression in reasonable time",
        ].joined(separator: "\n")

        let result = SwiftAcceptanceTestPreflight.classify(
            log: messages,
            in: fixture.root,
            testFolder: fixture.testFolder,
            expectedAPI: []
        )

        #expect(result.diagnostics.map(\.classification) == [
            .testAuthorMistake,
            .testAuthorMistake,
            .testAuthorMistake,
            .expected,
        ])
    }

    @Test
    func authorMistakesRerunTheTestAuthorWithoutStartingOrChargingTheImplementer() async throws {
        let diagnostic = CompilerDiagnostic(
            file: "Tests/AgentOSAdaptersTests/GH_29_1Tests/GH_29_1Tests.swift",
            line: 42,
            message: "expected expression",
            classification: .testAuthorMistake
        )
        let preflight = RecordingPreflight(outcomes: [
            .diagnostics([diagnostic], fullLog: "\(diagnostic.file):42: error: expected expression"),
            .compiled,
        ])
        let fixture = try await Fixture(preflight: preflight)

        _ = await fixture.reconciler.runRound()
        #expect(await fixture.testAuthor.tasks.count == 1)
        #expect(await fixture.implementer.tasks.isEmpty)
        let nodeAfterFirstAttempt = try await fixture.node()
        #expect(nodeAfterFirstAttempt.failedAttempts == 0)

        _ = await fixture.reconciler.runRound()
        #expect(await fixture.testAuthor.tasks.count == 2)
        #expect(await fixture.testAuthor.tasks.last?.previousFailure?.contains("expected expression") == true)
        #expect(await fixture.implementer.tasks.isEmpty)
        let nodeAfterRewrite = try await fixture.node()
        #expect(nodeAfterRewrite.failedAttempts == 0)

        _ = await fixture.reconciler.runRound()
        let implementationTask = try #require(await fixture.implementer.tasks.first)
        #expect(implementationTask.expectedAPI == ["NewRunner.run(timeZone:)"])
        let nodeAfterImplementation = try await fixture.node()
        #expect(nodeAfterImplementation.failedAttempts == 0)
    }

    @Test
    func returnCommentAndEvidenceExposeBoundedDiagnosticsAndTheFullCompilerLog() async throws {
        let diagnostics = (1...22).map {
            CompilerDiagnostic(
                file: $0.isMultiple(of: 2)
                    ? "Tests/AgentOSAdaptersTests/GH_29_1Tests/Support.swift"
                    : "Tests/AgentOSAdaptersTests/GH_29_1Tests/GH_29_1Tests.swift",
                line: $0,
                message: "author error \($0)",
                classification: .testAuthorMistake
            )
        }
        let fullLog = diagnostics.map { "\($0.file):\($0.line): error: \($0.message)" }.joined(separator: "\n")
        let fixture = try await Fixture(
            preflight: .init(outcomes: [.diagnostics(diagnostics, fullLog: fullLog)])
        )

        _ = await fixture.reconciler.runRound()

        let comment = try #require(await fixture.tracker.comments.last)
        #expect(comment.contains("GH_29_1Tests.swift"))
        #expect(comment.contains("Support.swift"))
        #expect(comment.contains("GH_29_1Tests.swift:1: author error 1"))
        #expect(comment.contains("Support.swift:20: author error 20"))
        #expect(!comment.contains("GH_29_1Tests.swift:21: author error 21"))
        #expect(comment.contains(".log"))

        let node = try await fixture.node()
        let evidence = try #require(node.evidence.last)
        #expect(evidence.summary.contains("author error 1"))
        #expect(try fixture.artifacts.contents(at: evidence.artifactPath) == fullLog)
    }

    @Test
    func reachingTheAuthorAttemptLimitWaitsForAPersonWithTheLatestError() async throws {
        let first = CompilerDiagnostic(
            file: "Tests/AgentOSAdaptersTests/GH_29_1Tests/GH_29_1Tests.swift",
            line: 7,
            message: "first syntax error",
            classification: .testAuthorMistake
        )
        let latest = CompilerDiagnostic(
            file: "Tests/AgentOSAdaptersTests/GH_29_1Tests/Support.swift",
            line: 19,
            message: "latest syntax error",
            classification: .testAuthorMistake
        )
        let fixture = try await Fixture(
            preflight: .init(outcomes: [
                .diagnostics([first], fullLog: "first log"),
                .diagnostics([latest], fullLog: "latest full compiler output"),
            ]),
            maxAttempts: 2
        )

        _ = await fixture.reconciler.runRound()
        _ = await fixture.reconciler.runRound()

        let node = try await fixture.node()
        #expect(node.flags[.needsInput]?.contains("Acceptance tests don't compile") == true)
        #expect(node.flags[.needsInput]?.contains("latest syntax error") == true)
        #expect(node.failedAttempts == 0)
        #expect(await fixture.testAuthor.tasks.count == 2)
        #expect(await fixture.implementer.tasks.isEmpty)
        let comment = try #require(await fixture.tracker.comments.last)
        #expect(comment.contains("Needs input"))
        #expect(comment.contains("Support.swift:19: latest syntax error"))
        #expect(comment.contains(".log"))
    }

    @Test
    func aRetestGivesTheTestAuthorFreshAttemptsAfterTheLimitWasReached() async throws {
        let mistake = CompilerDiagnostic(
            file: "Tests/AgentOSAdaptersTests/GH_29_1Tests/GH_29_1Tests.swift",
            line: 7,
            message: "syntax error",
            classification: .testAuthorMistake
        )
        let fixture = try await Fixture(
            preflight: .init(outcomes: Array(repeating: .diagnostics([mistake], fullLog: "log"), count: 3)),
            maxAttempts: 2
        )
        _ = await fixture.reconciler.runRound()
        _ = await fixture.reconciler.runRound()
        #expect(try await fixture.node().flags[.needsInput] != nil)

        try await fixture.ledger.append([
            LedgerEvent(node: Fixture.spec.id, by: .human("Alice"), kind: .flagCleared(.needsInput)),
            LedgerEvent(node: Fixture.spec.id, by: .human("Alice"), kind: .phaseChanged(to: .specified)),
        ])
        _ = await fixture.reconciler.runRound()

        #expect(try await fixture.node().flags[.needsInput] == nil)
        #expect(await fixture.testAuthor.tasks.count == 3)
        #expect(await fixture.tracker.comments.last?.contains("returned to the test author") == true)
    }

    @Test
    func theTestAuthorIsToldAboutTheNewestCompileErrorsNotAnOlderBrokenTestReport() async throws {
        let clash = CompilerDiagnostic(
            file: "Tests/AgentOSAdaptersTests/GH_15_4Tests/GH_15_4Tests.swift",
            line: 96,
            message: "'RecordingTracker' is ambiguous for type lookup in this context",
            classification: .testAuthorMistake
        )
        let fixture = try await Fixture(preflight: .init(outcomes: [.diagnostics([clash, clash], fullLog: "log")]))
        try await fixture.ledger.append([LedgerEvent(
            node: Fixture.spec.id,
            by: .agent(run: "run-old", role: .implementer),
            kind: .brokenTestReported(BrokenTestReport(testName: "GH_29_1Tests", reason: "old: 'Comment' is ambiguous"))
        )])

        _ = await fixture.reconciler.runRound()
        _ = await fixture.reconciler.runRound()

        let tasks = await fixture.testAuthor.tasks
        #expect(tasks.count == 2)
        let feedback = try #require(tasks.last?.previousFailure)
        #expect(!feedback.contains("old: 'Comment' is ambiguous"))
        #expect(feedback.contains("GH_15_4Tests.swift:96: 'RecordingTracker' is ambiguous"))
        #expect(feedback.components(separatedBy: "GH_15_4Tests.swift:96").count == 2)
        #expect(feedback.contains("`private`"))
    }
}

private struct ClassificationFixture {
    let root: URL
    let testFolder = "Tests/AgentOSAdaptersTests/GH_29_1Tests"
    let testFile: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "agentos-GH-29-1-classification-\(UUID().uuidString)")
        testFile = root.appending(path: "\(testFolder)/GH_29_1Tests.swift")
        let productionFile = root.appending(path: "Sources/Product/ExistingService.swift")
        try FileManager.default.createDirectory(
            at: testFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: productionFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        struct GH_29_1Tests {
            static let repeatedCrashLog = "crash"
        }
        """.write(to: testFile, atomically: true, encoding: .utf8)
        try """
        public struct ExistingService {
            public func run() {}
        }
        """.write(to: productionFile, atomically: true, encoding: .utf8)
    }
}

private struct Fixture {
    static let spec = NodeSpec(
        id: "wn-GH-29.1",
        parent: nil,
        kind: .leaf,
        title: "Preflight acceptance tests",
        intent: "Return broken tests to their author",
        acceptanceCriteria: ["Acceptance tests compile before implementation"]
    )

    let ledger: Ledger
    let tracker: RecordingTracker
    let testAuthor: RecordingTestAuthor
    let implementer: RecordingImplementer
    let preflight: RecordingPreflight
    let artifacts: RecordingArtifacts
    let reconciler: Reconciler

    init(preflight: RecordingPreflight, maxAttempts: Int = 3) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agentos-GH-29-1-\(UUID().uuidString)")
        let testFolder = directory.appending(path: "Tests/AgentOSAdaptersTests/GH_29_1Tests")
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)

        let ledger = try Ledger()
        try await ledger.append([
            LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .nodeCreated(spec: Self.spec, ticket: "GH-29.1")),
            LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .gateOpened(.breakdown)),
            LedgerEvent(node: Self.spec.id, by: .human("Alice"), kind: .gateOpened(.build)),
        ])

        let tracker = RecordingTracker()
        let testAuthor = RecordingTestAuthor()
        let implementer = RecordingImplementer()
        let artifacts = RecordingArtifacts()
        self.ledger = ledger
        self.tracker = tracker
        self.testAuthor = testAuthor
        self.implementer = implementer
        self.preflight = preflight
        self.artifacts = artifacts
        self.reconciler = Reconciler(
            ledger: ledger,
            tracker: tracker,
            external: NoExternalDependencies(),
            workspace: StubWorkspace(directory: directory),
            artifacts: artifacts,
            checks: PassingChecks(),
            team: AgentTeam(
                name: "acceptance",
                decomposer: NoopDecomposer(),
                testAuthor: testAuthor,
                implementer: implementer
            ),
            policy: Policy(maxAttempts: maxAttempts, guesswork: .autonomous),
            acceptanceTestPreflight: preflight
        )
    }

    func node() async throws -> NodeState {
        try #require(await ledger.workingState().nodes[Self.spec.id])
    }
}

private actor RecordingPreflight: AcceptanceTestPreflight {
    private var outcomes: [AcceptanceTestPreflightResult]
    private(set) var invocationCount = 0

    init(outcomes: [AcceptanceTestPreflightResult]) {
        self.outcomes = outcomes
    }

    func compileTests(in directory: URL, testFolder: String, expectedAPI: [String]) async -> AcceptanceTestPreflightResult {
        invocationCount += 1
        return outcomes.isEmpty ? .compiled : outcomes.removeFirst()
    }
}

private actor RecordingTestAuthor: TestAuthor {
    private(set) var tasks: [AgentTask] = []

    func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
        tasks.append(task)
        let file = task.directory.appending(path: "\(task.testFolder)/GH_29_1Tests.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// acceptance test attempt \(task.attempt)".write(to: file, atomically: true, encoding: .utf8)
        return AgentReport(expectedAPI: ["NewRunner.run(timeZone:)"])
    }
}

private actor RecordingImplementer: Implementer {
    private(set) var tasks: [AgentTask] = []

    func implement(_ task: AgentTask) async throws {
        tasks.append(task)
    }
}

private actor RecordingTracker: TrackerAdapter {
    private(set) var comments: [String] = []

    func pendingSignals() -> [Signal] { [] }

    func ticket(_ key: String) -> Ticket? {
        Ticket(
            key: key,
            title: "Preflight acceptance tests",
            description: "Return broken tests to their author",
            acceptanceCriteria: ["Acceptance tests compile before implementation"],
            createdBy: .human("Alice")
        )
    }

    func consume(_ signal: Signal, reply: String) {}
    func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String { "unused" }
    func comment(on key: String, _ text: String) { comments.append(text) }
    func setStatus(of key: String, to status: String) {}
}

private final class RecordingArtifacts: ArtifactStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func put(named name: String, contents: Data) throws -> StoredArtifact {
        lock.lock()
        defer { lock.unlock() }
        stored[name] = String(decoding: contents, as: UTF8.self)
        return StoredArtifact(path: name, sha256: Hashing.sha256(contents))
    }

    func contents(at path: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try #require(stored[path])
    }
}

private struct StubWorkspace: Workspace {
    let directory: URL

    func prepare() async throws {}
    func branch(for id: NodeID) -> String { "agentos/\(id)" }
    func worktree(for id: NodeID) -> URL { directory }
    func createWorktree(for id: NodeID) async throws -> URL { directory }
    func removeWorktree(for id: NodeID) async throws {}
    func commitAll(in directory: URL, message: String, author: String) async throws -> String? { "tests-\(author)" }
    func head(of directory: URL) async throws -> String { "candidate" }
    func changedFiles(in directory: URL) async throws -> [String] {
        ["Tests/AgentOSAdaptersTests/GH_29_1Tests/GH_29_1Tests.swift"]
    }
    var testArea: String { "Tests/AgentOSAdaptersTests/" }
    func testFolder(for spec: NodeSpec) -> String { "Tests/AgentOSAdaptersTests/GH_29_1Tests" }
    var agentContext: String { "" }
    func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
    func abortRebase(_ directory: URL) async throws {}
    func resetForRework(_ directory: URL) async throws {}
    func landOnMain(_ id: NodeID) async throws -> String { "landed" }
    func existingComponents() -> [String] { [] }
    func prepareBuild(in directory: URL) async throws {}
}

private struct PassingChecks: CheckRunner {
    func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
        CheckOutput(passed: true, summary: "passed", log: "")
    }
}

private struct NoExternalDependencies: ExternalDependencySource {
    func deliveredKeys() async -> Set<String> { [] }
}

private struct NoopDecomposer: Decomposer {
    func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
        Breakdown(children: [])
    }
}
