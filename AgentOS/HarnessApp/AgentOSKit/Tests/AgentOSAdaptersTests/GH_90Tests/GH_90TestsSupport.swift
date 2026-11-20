import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_90Tests {
    static func harness(_ enabled: Bool) -> HarnessSettings {
        var settings = HarnessSettings()
        settings.pullRequests = enabled
        return settings
    }

    static func resolve(_ enabled: Bool, repo: RepoConfig? = nil) -> EffectivePolicy {
        EffectivePolicy.resolve(harness: Self.harness(enabled), repo: repo, defaultBranch: "main")
    }

    static func configJSON(_ enabled: Bool) -> String {
        #"{"test":{"command":"swift test"},"pullRequests":\#(enabled)}"#
    }

    static func publishingSetting(_ policy: EffectivePolicy) throws -> EffectiveSetting {
        let rows = policy.settings.filter { $0.name == "Push / open pull requests" }
        #expect(rows.count == 1)
        return try #require(rows.first)
    }

    static func expectFullVerification(_ f: Fixture) async throws {
        #expect(await f.checks.calls.count == 1, "Run final verification exactly once per completed requirement.")
        let call = try #require(await f.checks.calls.first, "Final verification must actually run.")
        #expect(call.directory == f.requirementDirectory, "Check the requirement, not a leaf or main.")
        #expect(call.suite == nil, "Final verification must not select only the last leaf's suite.")
        #expect(try f.commandTrace().sorted() == ["format", "lint", "tests"])
        let evidence = await f.requirementEvidence()
        try #require(!evidence.isEmpty, "Record final verification in the requirement's ledger.")
        try Self.expectEvidence(evidence, in: f, passed: true, containing: "FORMAT tip-90")
    }

    static func expectEvidence(
        _ evidence: [Evidence], in f: Fixture, passed: Bool, containing output: String
    ) throws {
        let matching = evidence.filter { $0.passed == passed }
        try #require(!matching.isEmpty)
        var logs = ""
        for item in matching {
            #expect(item.commit == f.tip)
            #expect(item.specHash == f.spec(kind: .composite).specHash)
            let path = URL(fileURLWithPath: item.artifactPath)
            let resolved = path.path.hasPrefix(f.directory.path + "/")
                ? path : f.artifacts.directory.appending(path: item.artifactPath)
            let data = try Data(contentsOf: resolved)
            #expect(item.artifactSHA256 == Hashing.sha256(data))
            logs += String(decoding: data, as: UTF8.self)
        }
        #expect(logs.contains(output), "The full output must be recoverable from ledger-linked evidence.")
    }

    enum Failure: String, Sendable {
        case tests, lint
        var output: String {
            self == .tests ? "FinalAcceptance.testCheckout FAILED tip-90" : "LINT-90 rejected tip-90"
        }
    }

    final class Fixture: Sendable {
        let directory: URL
        let ledgerURL: URL
        let requirementDirectory: URL
        let requirement = NodeIdentity(ticketKey: "GH-90", nodeID: "wn-GH-90")
        let tip = "tip-90"
        let ledger: Ledger
        let artifacts: FileArtifactStore
        let workspace: MemoryWorkspace
        let checks: RecordingChecks
        let tracker = MemoryTracker()
        let agents = UnexpectedAgents()
        let publisher = RecordingPublisher()
        let policy: Policy
        let reconciler: Reconciler

        init(failure: Failure? = nil, policy: Policy = Policy()) throws {
            directory = FileManager.default.temporaryDirectory.appending(
                path: "GH-90-\(UUID().uuidString)"
            )
            requirementDirectory = directory.appending(path: "requirement")
            ledgerURL = directory.appending(path: "ledger.jsonl")
            try FileManager.default.createDirectory(at: requirementDirectory, withIntermediateDirectories: true)
            try "tip-90\n".write(to: requirementDirectory.appending(path: "branch-tip"), atomically: true, encoding: .utf8)
            if let failure {
                try Data().write(to: requirementDirectory.appending(path: "fail-\(failure.rawValue)"))
            }
            ledger = try Ledger(store: FileLedgerStore(fileURL: ledgerURL))
            artifacts = FileArtifactStore(directory: directory.appending(path: "artifacts"))
            workspace = MemoryWorkspace(root: directory, requirementDirectory: requirementDirectory)
            self.policy = policy
            let test = """
                while test -f hold; do sleep 0.05; done
                printf 'tests\\n' >> verification.trace
                printf 'FULL-TESTS '; cat branch-tip
                if test -f fail-tests; then printf 'FinalAcceptance.testCheckout FAILED tip-90\\n'; exit 1; fi
                """
            let lint = """
                printf 'lint\\n' >> verification.trace
                printf 'LINT '; cat branch-tip
                if test -f fail-lint; then printf 'LINT-90 rejected tip-90\\n'; exit 1; fi
                """
            let config = RepoConfig(
                test: .init(command: test, only: "--only {suite}"),
                checks: [
                    .init(name: "lint", command: lint),
                    .init(name: "format", command: "printf 'format\\n' >> verification.trace; printf 'FORMAT '; cat branch-tip"),
                ]
            )
            checks = RecordingChecks(runner: CommandCheckRunner(config: config))
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternalDependencies(),
                workspace: workspace, artifacts: artifacts, checks: checks,
                team: AgentTeam(name: "GH-90 no rework", decomposer: agents, testAuthor: agents, implementer: agents),
                policy: policy, publisher: publisher
            )
        }

        func makeReconciler(ledger: Ledger) -> Reconciler {
            Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternalDependencies(),
                workspace: workspace, artifacts: artifacts, checks: checks,
                team: AgentTeam(name: "GH-90 no rework", decomposer: agents, testAuthor: agents, implementer: agents),
                policy: policy, publisher: publisher
            )
        }

        func spec(kind: NodeKind, id: NodeID = "wn-GH-90", parent: NodeID? = nil) -> NodeSpec {
            NodeSpec(
                id: id, parent: parent, kind: kind, title: "Verify a finished requirement",
                intent: "Keep completed work local until a person merges it",
                acceptanceCriteria: ["Full verification passes before review"]
            )
        }

        func create(_ spec: NodeSpec, ticket: String, phase: Phase) async throws {
            await tracker.add(Ticket(
                key: ticket, title: spec.title, description: spec.intent,
                acceptanceCriteria: spec.acceptanceCriteria, createdBy: .human("Owner")
            ))
            try await ledger.append([
                LedgerEvent(node: spec.id, by: .human("Owner"), kind: .nodeCreated(spec: spec, ticket: ticket)),
                LedgerEvent(node: spec.id, by: .human("Owner"), kind: .gateOpened(.build)),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: phase)),
            ])
        }

        func seedSingleLeaf() async throws -> NodeSpec {
            let root = spec(kind: .leaf)
            try await create(root, ticket: requirement.ticketKey, phase: .building)
            return root
        }

        func seedComposite(nested: Bool = false) async throws -> [NodeSpec] {
            let root = spec(kind: .composite)
            try await create(root, ticket: requirement.ticketKey, phase: .split)
            let parent: NodeID
            if nested {
                parent = root.id + ".nested"
                try await create(spec(kind: .composite, id: parent, parent: root.id),
                                 ticket: "GH-90-NESTED", phase: .split)
            } else {
                parent = root.id
            }
            let leaves = (1...2).map { spec(kind: .leaf, id: "\(parent).\($0)", parent: parent) }
            for (index, leaf) in leaves.enumerated() {
                try await create(leaf, ticket: "GH-90-LEAF-\(index)", phase: .building)
            }
            return leaves
        }

        func seedCompletedComposite() async throws -> [NodeSpec] {
            let leaves = try await seedComposite()
            for leaf in leaves { try await prove(leaf) }
            return leaves
        }

        func prove(_ spec: NodeSpec) async throws {
            try await ledger.append([
                LedgerEvent(node: spec.id, by: .reconciler, kind: .landed(commit: tip)),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
            ])
        }

        func requirementEvidence(in source: Ledger? = nil) async -> [Evidence] {
            await (source ?? ledger).records(for: requirement.nodeID).compactMap {
                if case .evidenceRecorded(let evidence) = $0.event.kind { return evidence }
                return nil
            }
        }

        func settle(using alternative: Reconciler? = nil) async throws {
            let reconciler = alternative ?? self.reconciler
            try await withHangGuard("GH-90 reconciliation becoming idle") {
                while true {
                    try Task.checkCancellation()
                    let report = await reconciler.runRound(waitForAgents: true)
                    try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                    if report.isIdle { return }
                }
            }
        }

        func commandTrace() throws -> [String] {
            let path = requirementDirectory.appending(path: "verification.trace")
            if !FileManager.default.fileExists(atPath: path.path) { return [] }
            return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map(String.init)
        }

        func clearFailure(_ failure: Failure) throws {
            try FileManager.default.removeItem(at: requirementDirectory.appending(path: "fail-\(failure.rawValue)"))
        }

        func removeFiles() {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Could not remove GH-90 fixture files: \(error)") }
        }
    }

    actor RecordingChecks: CheckRunner {
        struct Call: Sendable {
            let directory: URL
            let suite: String?
        }
        let runner: CommandCheckRunner
        private(set) var calls: [Call] = []
        init(runner: CommandCheckRunner) { self.runner = runner }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            calls.append(Call(directory: directory, suite: testTarget))
            return await runner.runChecks(in: directory, only: testTarget)
        }
    }

    actor RecordingPublisher: RequirementPublisher {
        struct Call: Sendable {
            let requirement: NodeIdentity
            let branch: String
            let commit: String
        }
        private(set) var calls: [Call] = []
        func publish(requirement: NodeIdentity, branch: String, commit: String) async throws {
            calls.append(Call(requirement: requirement, branch: branch, commit: commit))
        }
    }

    actor MemoryWorkspace: Workspace {
        nonisolated let root: URL
        nonisolated let requirementDirectory: URL
        private var merged = false
        private(set) var mergeQueries: [NodeIdentity] = []
        private(set) var mergeWrites = 0
        init(root: URL, requirementDirectory: URL) {
            self.root = root
            self.requirementDirectory = requirementDirectory
        }
        func requirementWorktree(for requirement: NodeIdentity) async throws -> URL { requirementDirectory }
        func requirementIsMerged(_ requirement: NodeIdentity) async throws -> Bool {
            mergeQueries.append(requirement)
            return merged
        }
        func personMergesRequirementIntoMain() { merged = true }
        func prepare() async throws {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: "leaves/\(id)") }
        func createWorktree(for id: NodeID) async throws -> URL {
            throw AgentFailure("Final verification must not create another leaf worktree")
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Final verification must not commit new implementation")
        }
        func head(of directory: URL) async throws -> String {
            directory == requirementDirectory ? "tip-90" : "different-leaf-or-main-tip"
        }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {
            throw AgentFailure("Final verification must not reset a proven leaf")
        }
        func landOnMain(_ id: NodeID) async throws -> String {
            mergeWrites += 1
            throw AgentFailure("Final verification must not merge into main")
        }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    actor UnexpectedAgents: Decomposer, TestAuthor, Implementer {
        private(set) var calls: [AgentRole] = []
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            calls.append(.decomposer)
            throw AgentFailure("Final verification must not launch a decomposer")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            calls.append(.testAuthor)
            throw AgentFailure("Final verification must not launch a test author")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            calls.append(.implementer)
            throw AgentFailure("Final verification must not launch an implementer")
        }
    }

    actor MemoryTracker: TrackerAdapter {
        private var tickets: [String: Ticket] = [:]
        private var signals: [Signal] = []
        func add(_ ticket: Ticket) { tickets[ticket.key] = ticket }
        func addRetry(for key: String) {
            signals.append(Signal(ticket: key, command: .retry, setBy: .human("Owner")))
        }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? { tickets[key] }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            comment(on: signal.ticket, reply)
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("GH-90 already has its breakdown")
        }
        func comment(on key: String, _ text: String) {
            tickets[key]?.comments.append(Comment(author: .reconciler, text: text))
        }
        func comments(on key: String) -> [String] { tickets[key]?.comments.map(\.text) ?? [] }
        func setStatus(of key: String, to status: String) { tickets[key]?.status = status }
    }

    struct NoExternalDependencies: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
}
