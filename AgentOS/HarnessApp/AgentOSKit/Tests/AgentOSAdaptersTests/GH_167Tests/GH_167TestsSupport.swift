import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_167Tests {
    struct Tree: Sendable {
        let parent: NodeSpec
        let ticket: String
        let producer: NodeSpec
        let consumer: NodeSpec
        let integration: NodeSpec
    }

    struct AuthorObservation: Sendable {
        let output: String
        let head: String
        let requirementHead: String
        let testPassed: Bool
    }

    actor Agents: Decomposer, TestAuthor, AgentOSCore.Implementer {
        var authored: [NodeID: AuthorObservation] = [:]
        var implemented: [NodeID: AgentTask] = [:]
        var unchangedIntegrationChecks: [NodeID: CheckOutput] = [:]
        private var stopsAfterScopeCapture = false

        func stopAfterScopeCapture() { stopsAfterScopeCapture = true }

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            Breakdown(children: [])
        }

        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            let script: String
            switch task.spec.title {
            case "Producer": script = "test \"$(sh Sources/Producer/value.sh)\" = hello\n"
            case "Consumer": script = "test \"$(printf 'hello\\n' | sh Sources/Consumer/format.sh)\" = 'hello world'\n"
            default: script = "test \"$(sh workflow.sh)\" = 'hello world'\n"
            }
            try GH_167Tests.write(script, to: task.directory.appending(path: task.testFolder + "/check.sh"))
            let output = try await GH_167Tests.command("sh workflow.sh", in: task.directory)
            let check = await CommandCheckRunner(config: GH_167Tests.config)
                .runChecks(in: task.directory, only: task.spec.testTarget)
            let parentTicket = task.agentContext.parent?.key ?? task.identity.ticketKey
            authored[task.spec.id] = AuthorObservation(
                output: output.output,
                head: try await GH_167Tests.git(["rev-parse", "HEAD"], in: task.directory),
                requirementHead: try await GH_167Tests.git(["rev-parse", "agentos/\(parentTicket)"], in: task.directory),
                testPassed: check.passed)
            return AgentReport()
        }

        func implement(_ task: AgentTask) async throws -> AgentReport {
            implemented[task.spec.id] = task
            if task.spec.integration {
                if stopsAfterScopeCapture {
                    return AgentReport(questions: [AgentQuestion(question: "The fixture has captured its integration scope.")])
                }
                unchangedIntegrationChecks[task.spec.id] = await CommandCheckRunner(config: GH_167Tests.config)
                    .runChecks(in: task.directory, only: task.spec.testTarget)
                return AgentReport(alreadySatisfied: true)
            }
            switch task.spec.title {
            case "Producer":
                try GH_167Tests.write("printf 'hello\\n'\n",
                                     to: task.directory.appending(path: "Sources/Producer/value.sh"))
            case "Consumer":
                try GH_167Tests.write("sed 's/$/ world/'\n",
                                     to: task.directory.appending(path: "Sources/Consumer/format.sh"))
            default:
                throw AgentFailure("Unexpected ordinary fixture leaf: \(task.spec.title)")
            }
            return AgentReport()
        }
    }

    struct Fixture: Sendable {
        let root: URL
        let repo: URL
        let ledger: Ledger
        let tracker: LocalTracker
        let workspace: RepositoryWorkspace
        let agents: Agents
        let reconciler: Reconciler

        func record(_ node: NodeID, _ kinds: [EventKind]) async throws {
            try await ledger.append(kinds.map { LedgerEvent(node: node, by: .human("Test author"), kind: $0) })
        }

        @discardableResult
        func add(_ spec: NodeSpec, phase: Phase = .specified, gates: [Gate] = []) async throws -> String {
            let state = await ledger.workingState()
            let parentKey = spec.parent.flatMap { state.nodes[$0]?.ticket }
            let ticket = await tracker.createTicket(
                title: spec.title, description: spec.intent, acceptanceCriteria: spec.acceptanceCriteria,
                parentKey: parentKey, by: .human("Test author"))
            try await record(spec.id, [.nodeCreated(spec: spec, ticket: ticket.key), .phaseChanged(to: phase)]
                             + gates.map { .gateOpened($0) })
            return ticket.key
        }

        func settle() async throws {
            try await withHangGuard("GH-167 reconciler reaching an idle state") {
                while true {
                    let round = await reconciler.runRound(waitForAgents: true)
                    try #require(round.safeStop == nil, "\(round.safeStop ?? "")")
                    if round.isIdle { return }
                    try Task.checkCancellation()
                }
            }
        }
    }

    static var config: RepoConfig {
        RepoConfig(test: .init(command: "sh run-tests.sh", only: "{suite}"),
                   leafTests: .init(target: "Checks", folder: "Tests/Checks"))
    }

    static func spec(_ name: String, parent: NodeID? = nil, kind: NodeKind = .leaf,
                     title: String? = nil, touches: [String]) -> NodeSpec {
        NodeSpec(id: "wn-GH167-\(name)", parent: parent, kind: kind, title: title ?? name,
                 intent: "Prove a greeting workflow", acceptanceCriteria: ["The greeting workflow works"],
                 touches: touches, predictedPaths: touches.map { "Sources/\($0)" })
    }

    static func standardTree(in fixture: Fixture) async throws -> Tree {
        let parent = Self.spec("parent", kind: .composite, touches: ["Workflow"])
        let ticket = try await fixture.add(parent, phase: .split, gates: [.breakdown])
        let planned = Planner.childSpecs(parent: parent, proposals: [
            ChildProposal(title: "Producer", acceptanceCriteria: ["The producer emits hello"],
                          touches: ["Producer"], predictedPaths: ["Sources/Producer"]),
            ChildProposal(title: "Consumer", acceptanceCriteria: ["The consumer adds world"],
                          touches: ["Consumer"], predictedPaths: ["Sources/Consumer"]),
            ChildProposal(title: "Combined workflow", acceptanceCriteria: ["The workflow says hello world"],
                          touches: ["Seams"], predictedPaths: ["workflow.sh"], integration: true)
        ])
        try #require(planned.count == 3)
        try await fixture.add(planned[0], gates: [.build])
        try await fixture.add(planned[1], gates: [.build])
        try await fixture.add(planned[2])
        return Tree(parent: parent, ticket: ticket, producer: planned[0], consumer: planned[1], integration: planned[2])
    }

    static func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Self.makeFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.reconciler.shutdown(reason: "GH-167 test failed")
            try FileManager.default.removeItem(at: fixture.root)
            throw error
        }
        await fixture.reconciler.shutdown(reason: "GH-167 test finished")
        try FileManager.default.removeItem(at: fixture.root)
    }

    private static func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "GH_167Tests-\(UUID().uuidString)")
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        do {
            _ = try await Self.git(["init", "-q", "-b", "main"], in: repo)
            _ = try await Self.git(["config", "user.name", "GH-167 fixture"], in: repo)
            _ = try await Self.git(["config", "user.email", "gh167@example.invalid"], in: repo)
            _ = try await Self.git(["config", "commit.gpgsign", "false"], in: repo)
            try Self.write(".agentos/\n.build/\n", to: repo.appending(path: ".gitignore"))
            try Self.write("printf 'pending\\n'\n", to: repo.appending(path: "Sources/Producer/value.sh"))
            try Self.write("cat\n", to: repo.appending(path: "Sources/Consumer/format.sh"))
            try Self.write("sh Sources/Producer/value.sh | sh Sources/Consumer/format.sh\n",
                           to: repo.appending(path: "workflow.sh"))
            try Self.write("""
                set -eu
                if [ "$#" -gt 0 ]; then
                    sh "Tests/Checks/$1/check.sh"
                    exit $?
                fi
                for test in Tests/Checks/*/check.sh; do
                    [ -f "$test" ] || continue
                    sh "$test"
                done

                """, to: repo.appending(path: "run-tests.sh"))
            _ = try await Self.git(["add", "."], in: repo)
            _ = try await Self.git(["-c", "commit.gpgsign=false", "commit", "-q", "-m", "Fixture public workflow"], in: repo)
            let ledger = try Ledger()
            let tracker = LocalTracker(project: "GH167", store: nil)
            let agents = Agents()
            let workspace = try RepositoryWorkspace(
                root: repo, storage: root.appending(path: "storage"), config: Self.config,
                landingBranch: "agentos/test", defaultBranch: "main")
            var policy = Policy(maxParallelAgents: 4, guesswork: .autonomous)
            policy.infrastructureRetryDelays = []
            let reconciler = Reconciler(
                ledger: ledger, tracker: LocalTrackerAdapter(tracker: tracker), external: NoExternalSystem(),
                workspace: workspace, artifacts: FileArtifactStore(directory: workspace.artifactsDirectory),
                checks: CommandCheckRunner(config: Self.config),
                team: AgentTeam(name: "GH-167 fixtures", decomposer: agents, testAuthor: agents, implementer: agents),
                policy: policy, requirementBranches: workspace)
            return Fixture(root: root, repo: repo, ledger: ledger, tracker: tracker,
                           workspace: workspace, agents: agents, reconciler: reconciler)
        } catch {
            try FileManager.default.removeItem(at: root)
            throw error
        }
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func command(_ command: String, in directory: URL) async throws -> ProcessRunner.Result {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", command], in: directory, timeout: .seconds(60))
        try #require(result.status == 0, "\(result.output)")
        return result
    }

    static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory, timeout: .seconds(60))
        try #require(result.status == 0, "git \(arguments): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isAncestor(_ commit: String, of descendant: String, in directory: URL) async throws -> Bool {
        let result = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "merge-base", "--is-ancestor", commit, descendant], in: directory, timeout: .seconds(60))
        try #require(result.status == 0 || result.status == 1, "\(result.output)")
        return result.status == 0
    }

    static func proves(_ kind: EventKind) -> Bool {
        if case .phaseChanged(to: .proven) = kind { return true }
        if case .landed = kind { return true }
        return false
    }

    static func promptTask(integration: Bool) -> AgentTask {
        var node = Self.spec("prompt", title: "Greeting workflow", touches: ["Workflow"])
        node.integration = integration
        return Self.promptTask(spec: node)
    }

    static func promptTask(spec: NodeSpec) -> AgentTask {
        let directory = URL(filePath: #filePath).deletingLastPathComponent()
        return AgentTask(spec: spec, run: "gh167-prompt", directory: directory,
                         testFolder: "Tests/Checks/GH167PromptTests", scratchDirectory: directory.appending(path: "scratch"),
                         guesswork: .autonomous)
    }

    static func instructions(_ prompt: String) -> String {
        prompt.components(separatedBy: "<<<SPEC").first ?? prompt
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        let normalized = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }
}
