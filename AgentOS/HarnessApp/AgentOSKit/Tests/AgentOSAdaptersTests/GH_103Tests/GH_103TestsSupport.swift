import AgentOSAdapters
import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSCore

extension GH_103Tests {
    static var pass: CheckOutput {
        CheckOutput(passed: true, summary: "all tests passed", log: "Executed 4 tests, with 0 failures.\nGH-103 full suite passed")
    }

    static func marker(_ id: NodeID) -> String { "Changes/\(id)/first.txt" }
    static func subjects(for id: NodeID) -> [String] { ["\(id) acceptance", "\(id) first", "\(id) second"] }

    struct Requirement: Sendable {
        let spec: NodeSpec
        let ticket: String
        var branch: String { "agentos/\(ticket)" }
        var identity: NodeIdentity { NodeIdentity(ticketKey: ticket, nodeID: spec.id) }
    }

    struct Leaf: Sendable {
        let spec: NodeSpec
        let ticket: String
        var id: NodeID { spec.id }
        var builder: RunID { "builder-\(id)" }
    }

    final class Fixture: Sendable {
        let directory: URL
        let repo: URL
        let ledgerFile: URL
        let initialMain: String
        let workspace: RepositoryWorkspace
        let ledger: Ledger
        let tracker = RecordingTracker()
        let checks: RecordingChecks
        let agents = GatedAgents()
        let reconciler: Reconciler

        init(batchSize: Int, maxParallelAgents: Int = 4, holdFirstCheck: Bool = false,
             outputs: [CheckOutput]? = nil, reviewLevel: ReviewLevel = .none,
             reviewer: (any Reviewer)? = nil) async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "GH-103-\(UUID())")
            let cleanupDirectory = directory
            var initialized = false
            defer {
                if !initialized {
                    do { try FileManager.default.removeItem(at: cleanupDirectory) }
                    catch { Issue.record("Could not clean up an incomplete GH-103 fixture: \(error)") }
                }
            }
            repo = directory.appending(path: "repo")
            ledgerFile = directory.appending(path: "ledger.jsonl")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try await Self.git(["init", "-q", "-b", "main"], in: repo)
            try await Self.git(["config", "user.name", "GH-103 fixture"], in: repo)
            try await Self.git(["config", "user.email", "gh103@example.invalid"], in: repo)
            try "base\n".write(to: repo.appending(path: "base.txt"), atomically: true, encoding: .utf8)
            try await Self.git(["add", "."], in: repo)
            try await Self.git(["commit", "-q", "-m", "initial"], in: repo)
            initialMain = try await Self.git(["rev-parse", "main"], in: repo)
            #expect(try await Self.git(["show", "\(initialMain):base.txt"], in: repo) == "base",
                    "Validate the repository reader against a known existing git commit")
            workspace = try RepositoryWorkspace(
                root: repo, storage: directory.appending(path: "storage"),
                config: RepoConfig(test: .init(command: "true"),
                                   leafTests: .init(target: "AppTests", folder: "Tests/AppTests")),
                landingBranch: "agentos/main", defaultBranch: "main")
            ledger = try Ledger(store: FileLedgerStore(fileURL: ledgerFile))
            checks = RecordingChecks(repo: repo, initialMain: initialMain, holdFirst: holdFirstCheck, outputs: outputs)
            var policy = Policy(maxParallelAgents: maxParallelAgents, guesswork: .autonomous,
                                avoidOverlappingWork: false)
            policy.landingBatchSize = batchSize
            policy.infrastructureRetryDelays = []
            policy.review.level = reviewLevel
            var team = AgentTeam(name: "GH-103", decomposer: agents, testAuthor: agents, implementer: agents)
            team.reviewer = reviewer
            reconciler = Reconciler(ledger: ledger, tracker: tracker, external: NoExternal(),
                                    workspace: workspace, artifacts: FileArtifactStore(directory: directory.appending(path: "artifacts")),
                                    checks: checks, team: team, policy: policy)
            try await workspace.prepare()
            initialized = true
        }

        func addRequirement(_ ticket: String) async throws -> Requirement {
            let spec = NodeSpec(id: "wn-\(ticket)", parent: nil, kind: .composite, title: ticket,
                                intent: "Land a requirement's leaves", acceptanceCriteria: ["Leaves share a branch"])
            let root = Requirement(spec: spec, ticket: ticket)
            let from = try #require(try await workspace.prepareRequirementBranch(for: root.identity, leaves: []))
            try await ledger.append([
                LedgerEvent(node: spec.id, by: .human("Developer"), kind: .nodeCreated(spec: spec, ticket: ticket)),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .split)),
                LedgerEvent(node: spec.id, by: .reconciler, kind: .requirementBranchCreated(branch: root.branch, from: from)),
            ])
            return root
        }

        func addUnbuiltLeaf(_ name: String, under root: Requirement) async throws -> Leaf {
            let spec = NodeSpec(id: "wn-\(name)", parent: root.spec.id, kind: .leaf, title: name,
                                intent: "Keep \(name) as distinct work", acceptanceCriteria: ["Implement \(name)"])
            let leaf = Leaf(spec: spec, ticket: "WORK-\(name)")
            _ = try await workspace.prepareRequirementBranch(for: root.identity, leaves: [leaf.id])
            try await ledger.append([
                LedgerEvent(node: leaf.id, by: .human("Developer"), kind: .nodeCreated(spec: spec, ticket: leaf.ticket)),
            ])
            return leaf
        }

        func addLeaf(_ name: String, under root: Requirement, uiEvidence: Bool = false) async throws -> Leaf {
            let leaf = try await addUnbuiltLeaf(name, under: root)
            let checkout = try await workspace.createWorktree(for: leaf.id)
            let folder = workspace.testFolder(for: leaf.spec)
            try Self.write("acceptance for \(leaf.id)\n", to: "\(folder)/Acceptance.txt", in: checkout)
            _ = try #require(try await workspace.commitAll(in: checkout, message: "\(leaf.id) acceptance", author: "test-author"))
            let digest = Hashing.digest(of: checkout.appending(path: folder))
            try Self.write("first change for \(leaf.id)\n", to: GH_103Tests.marker(leaf.id), in: checkout)
            if uiEvidence {
                let evidence = UIReviewEvidence(snapshotPaths: [".agentos-ui-evidence/\(leaf.id).txt"],
                                                windowsOpened: true, windowsClosed: true,
                                                beforeScreenshot: nil, afterScreenshot: nil)
                try JSONEncoder().encode(evidence).write(to: checkout.appending(path: ".agentos-ui-evidence.json"))
                try Self.write("node-specific review artifact\n", to: ".agentos-ui-evidence/\(leaf.id).txt", in: checkout)
            }
            _ = try #require(try await workspace.commitAll(in: checkout, message: "\(leaf.id) first", author: "implementer"))
            try Self.write("second change for \(leaf.id)\n", to: "Changes/\(leaf.id)/second.txt", in: checkout)
            let commit = try #require(try await workspace.commitAll(in: checkout, message: "\(leaf.id) second", author: "implementer"))
            try await ledger.append([
                LedgerEvent(node: leaf.id, by: .reconciler, kind: .testsFixed(digest: digest)),
                LedgerEvent(node: leaf.id, by: .agent(run: leaf.builder, role: .implementer),
                            kind: .changeSubmitted(run: leaf.builder, commit: commit)),
                LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
            ])
            await checks.register(leaf, branch: root.branch)
            return leaf
        }

        func enqueue(_ leaves: [Leaf]) async throws {
            try await ledger.append(leaves.map {
                LedgerEvent(node: $0.id, by: .reconciler, kind: .phaseChanged(to: .landing))
            })
        }

        func round(waitForAgents: Bool = true) async throws -> RoundReport {
            let report = try await withHangGuard("the GH-103 reconciler round") {
                await self.reconciler.runRound(waitForAgents: waitForAgents)
            }
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
            return report
        }

        func finishLandings(_ leaves: [Leaf]) async throws {
            try await withHangGuard("all requested leaves landing") {
                while true {
                    let state = await self.ledger.workingState()
                    if leaves.allSatisfy({ state.nodes[$0.id]?.phase == .proven }) { return }
                    let report = try await self.round()
                    let after = await self.ledger.workingState()
                    let comments = await self.tracker.allComments()
                    try #require(!report.isIdle || leaves.allSatisfy { after.nodes[$0.id]?.phase == .proven },
                                 "Landing stopped early: \(comments)")
                }
            }
        }

        func checkout(_ root: Requirement) async throws -> URL {
            let checkout = directory.appending(path: "human-checkout-\(UUID())")
            try await git(["worktree", "add", "-q", checkout.path, root.branch])
            return checkout
        }

        func removeCheckout(_ checkout: URL) async throws {
            try await git(["worktree", "remove", checkout.path])
        }

        func advance(_ root: Requirement, file: String) async throws -> String {
            let before = try await revision(root.branch)
            let snapshot = try await workspace.requirementWorktree(for: root.identity)
            try Self.write("new requirement work\n", to: file, in: snapshot)
            let commit = try #require(try await workspace.commitAll(in: snapshot, message: file, author: "another-developer"))
            try await git(["update-ref", "refs/heads/\(root.branch)", commit, before])
            await workspace.removeSnapshot(snapshot)
            return commit
        }

        func revision(_ ref: String) async throws -> String { try await git(["rev-parse", "--verify", ref]) }
        func paths(at ref: String) async throws -> [String] {
            try await git(["ls-tree", "-r", "--name-only", ref]).split(separator: "\n").map(String.init)
        }
        func contains(_ ancestor: String, in descendant: String) async throws -> Bool {
            let result = try await ProcessRunner.run("/usr/bin/env", ["git", "merge-base", "--is-ancestor", ancestor, descendant], in: repo)
            try #require(result.status == 0 || result.status == 1, "\(result.output)")
            return result.status == 0
        }
        @discardableResult
        func git(_ arguments: [String]) async throws -> String { try await Self.git(arguments, in: repo) }
        @discardableResult
        static func git(_ arguments: [String], in directory: URL) async throws -> String {
            let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
            try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        static func write(_ text: String, to path: String, in directory: URL) throws {
            let file = directory.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        func cleanUp() {
            checks.release.open()
            agents.release.open()
            do { try FixtureFolder.remove(directory) }
            catch { Issue.record("Could not remove the GH-103 fixture: \(error)") }
        }
    }

    actor RecordingChecks: CheckRunner {
        struct Call: Sendable {
            let directory: URL
            let selection: String?
            let commit: String
            let members: [NodeID]
            let subjects: [String]
            let tips: [String: String]
        }
        let repo: URL
        let initialMain: String
        let holdFirst: Bool
        let outputs: [CheckOutput]?
        nonisolated let entered = TestGate()
        nonisolated let release = TestGate()
        private var branches: [NodeID: String] = [:]
        private var fixedOutput: CheckOutput?
        private var activeCalls = 0
        private(set) var maximumConcurrentCalls = 0
        private(set) var calls: [Call] = []

        init(repo: URL, initialMain: String, holdFirst: Bool, outputs: [CheckOutput]?) {
            self.repo = repo
            self.initialMain = initialMain
            self.holdFirst = holdFirst
            self.outputs = outputs
        }
        func register(_ leaf: Leaf, branch: String) { branches[leaf.id] = branch }
        func returnEveryTime(_ output: CheckOutput) { fixedOutput = output }

        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            activeCalls += 1
            maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
            defer { activeCalls -= 1 }
            do {
                let commit = try await Fixture.git(["rev-parse", "HEAD"], in: directory)
                let subjects = try await Fixture.git(["log", "--reverse", "--format=%s", "\(initialMain)..HEAD"], in: directory)
                    .split(separator: "\n").map(String.init)
                let paths = Set(try await Fixture.git(["ls-tree", "-r", "--name-only", "HEAD"], in: directory)
                    .split(separator: "\n").map(String.init))
                var tips: [String: String] = [:]
                var newMembers: Set<NodeID> = []
                for branch in Set(branches.values) {
                    let tip = try await Fixture.git(["rev-parse", branch], in: repo)
                    tips[branch] = tip
                    let existing = Set(try await Fixture.git(["ls-tree", "-r", "--name-only", tip], in: repo)
                        .split(separator: "\n").map(String.init))
                    for (id, owner) in branches where owner == branch {
                        if paths.contains(GH_103Tests.marker(id)) && !existing.contains(GH_103Tests.marker(id)) {
                            newMembers.insert(id)
                        }
                    }
                }
                let ordered = subjects.compactMap { subject -> NodeID? in
                    guard subject.hasSuffix(" first") else { return nil }
                    let node = String(subject.dropLast(" first".count))
                    return newMembers.contains(node) ? node : nil
                }
                let selectedSubjects = subjects.filter { subject in
                    newMembers.contains { subject.hasPrefix($0 + " ") }
                }
                let index = calls.count
                calls.append(Call(directory: directory.standardizedFileURL, selection: testTarget, commit: commit,
                                  members: ordered, subjects: selectedSubjects, tips: tips))
                if index == 0 {
                    entered.open()
                    if holdFirst { try await release.wait() }
                }
                if let outputs {
                    guard outputs.indices.contains(index) else {
                        Issue.record("Unexpected extra GH-103 check #\(index + 1)")
                        return CheckOutput(passed: false, summary: "check script exhausted", log: "check script exhausted")
                    }
                    return outputs[index]
                }
                return fixedOutput ?? GH_103Tests.pass
            } catch {
                Issue.record("Could not observe the checked git candidate: \(error)")
                return CheckOutput(passed: false, summary: "fixture check failed", log: "\(error)")
            }
        }
    }

    actor RecordingTracker: TrackerAdapter {
        private var recorded: [String: [String]] = [:]
        func comments(on ticket: String) -> [String] { recorded[ticket, default: []] }
        func allComments() -> String { recorded.values.flatMap { $0 }.joined(separator: "\n") }
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async {}
        func comment(on key: String, _ text: String) async { recorded[key, default: []].append(text) }
        func setStatus(of key: String, to status: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("No test in GH-103 should create tracker tickets")
        }
    }

    actor GatedAgents: Decomposer, TestAuthor, Implementer {
        nonisolated let entered = TestGate()
        nonisolated let release = TestGate()
        private(set) var started: [NodeID] = []
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH-103 starts with already-broken-down requirements")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            started.append(task.spec.id)
            entered.open()
            try await release.wait()
            return AgentReport(questions: ["Fixture stops ordinary work after observing its agent slot"])
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-103 starts with already-submitted implementations")
        }
    }

    actor RecordingReviewer: Reviewer {
        let passed: Bool
        private(set) var requests: [ReviewRequest] = []
        init(passed: Bool) { self.passed = passed }
        func review(_ request: ReviewRequest) async throws -> ReviewResult {
            requests.append(request)
            return ReviewResult(passed: passed, findings: passed ? [] : ["Return the missing validation error"])
        }
    }

    struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
}
