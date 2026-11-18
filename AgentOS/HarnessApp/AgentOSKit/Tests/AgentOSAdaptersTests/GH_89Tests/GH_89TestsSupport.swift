import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_89Tests {
    enum BaselineCase: CaseIterable, Sendable { case missing, failed, stale }

    final class Gate: Sendable {
        let entered = TestGate()
        private let released = TestGate()
        func pause() async throws {
            entered.open()
            try await released.wait(for: "GH-89 explicit gate release")
        }
        func release() { released.open() }
    }

    static func event(_ event: LedgerEvent, mentions values: [String]) throws -> Bool {
        func strings(_ value: Any) -> [String] {
            if let text = value as? String { return [text] }
            if let array = value as? [Any] { return array.flatMap(strings) }
            if let object = value as? [String: Any] { return object.values.flatMap(strings) }
            return []
        }
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
        let text = strings(payload)
        return values.allSatisfy { wanted in text.contains { $0.contains(wanted) } }
    }

    static func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let f = try Fixture()
        do { try await body(f) }
        catch {
            await f.reconciler.shutdown(reason: "GH-89 failed")
            try FileManager.default.removeItem(at: f.root)
            throw error
        }
        await f.reconciler.shutdown(reason: "GH-89 finished")
        try FileManager.default.removeItem(at: f.root)
    }

    final class Fixture: Sendable {
        let root: URL
        let ledger: Ledger
        let tracker = Tracker()
        let agents = Agents()
        let workspace: Branches
        let checks: Checks
        var reconciler: Reconciler { storedReconciler }
        private let storedReconciler: Reconciler

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH-89-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            ledger = try Ledger()
            workspace = Branches(root: root)
            checks = Checks(workspace: workspace)
            storedReconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: External(), workspace: workspace,
                artifacts: Artifacts(), checks: checks, team: agents.team,
                policy: Policy(maxParallelAgents: 4), requirementBranches: workspace)
        }

        func makeReconciler() -> Reconciler {
            Reconciler(ledger: ledger, tracker: tracker, external: External(), workspace: workspace,
                       artifacts: Artifacts(), checks: checks, team: agents.team,
                       policy: Policy(maxParallelAgents: 4), requirementBranches: workspace)
        }

        func record(_ node: NodeID?, _ kinds: [EventKind]) async throws {
            try await ledger.append(kinds.map { LedgerEvent(node: node, by: .human("Alice"), kind: $0) })
        }

        func baseline(_ commit: String, passed: Bool = true) async throws {
            try await record(nil, [.baselineChecked(Baseline(
                commit: commit, passed: passed, summary: passed ? "Passed" : "Failed", seconds: 0, log: nil))])
        }

        func requirement(_ id: NodeID, ticket: String, dependsOn: [String] = [], closed: Bool = false) async throws {
            try await workspace.addRequirement(ticket)
            try await seed(id, ticket: ticket, kind: .composite, phase: .split, dependsOn: dependsOn)
            if closed {
                await tracker.closeByPerson(ticket)
                try await record(id, [.ticketClosed])
            }
        }

        func composite(_ id: NodeID, parent: NodeID) async throws {
            try await seed(id, parent: parent, kind: .composite, phase: .split)
        }

        func leaf(_ id: NodeID, parent: NodeID? = nil, ticket: String? = nil, phase: Phase = .ready,
                  paths: [String]? = nil, tests: Bool = true, build: Bool = false, running: Bool = false) async throws {
            let key = ticket ?? id
            if parent == nil { try await workspace.addRequirement(key) }
            let state = await ledger.workingState()
            let requirementTicket = parent.flatMap { state.lineage(of: $0).last?.ticket } ?? key
            let files = paths ?? ["Sources/\(id).swift"]
            try await workspace.addLeaf(id, requirement: requirementTicket, files: files)
            try await seed(id, ticket: key, parent: parent, kind: .leaf, phase: phase, paths: files, tests: tests)
            if build { try await record(id, [.gateOpened(.build)]) }
            if phase == .checking || phase == .landing {
                let commit = try await workspace.head(of: workspace.worktree(for: id))
                try await record(id, [.changeSubmitted(run: "builder-\(id)", commit: commit)])
            }
            if running { try await record(id, [.runStarted(run: "existing-\(id)", role: .implementer)]) }
            if phase == .proven {
                let commit = try await workspace.landOnMain(id)
                try await record(id, [.landed(commit: commit)])
            }
        }

        private func seed(_ id: NodeID, ticket: String? = nil, parent: NodeID? = nil, kind: NodeKind,
                          phase: Phase, paths: [String] = [], tests: Bool = false, dependsOn: [String] = []) async throws {
            let key = ticket ?? id
            let spec = NodeSpec(id: id, parent: parent, kind: kind, title: id, intent: "GH-89 branch isolation",
                                acceptanceCriteria: ["Observable behaviour for \(id)"], predictedPaths: paths,
                                dependsOn: dependsOn)
            await tracker.add(Ticket(key: key, title: id, description: spec.intent,
                                     acceptanceCriteria: spec.acceptanceCriteria, createdBy: .human("Alice")))
            var events: [EventKind] = [.nodeCreated(spec: spec, ticket: key), .phaseChanged(to: phase)]
            if tests {
                let folder = workspace.worktree(for: id).appending(path: workspace.testFolder(for: spec))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try "fixed acceptance tests\n".write(
                    to: folder.appending(path: "acceptance.txt"), atomically: true, encoding: .utf8)
                events.append(.testsFixed(digest: Hashing.digest(of: folder)))
            }
            try await record(id, events)
        }

        @discardableResult
        func round(using other: Reconciler? = nil, waitForAgents: Bool = true) async throws -> RoundReport {
            let result = await (other ?? reconciler).runRound(waitForAgents: waitForAgents)
            try #require(result.safeStop == nil, "\(result.safeStop ?? "")")
            return result
        }

        func settle(using other: Reconciler? = nil) async throws {
            for _ in 0..<20 {
                if try await round(using: other).isIdle { return }
            }
            Issue.record("The finite, immediate fake agents must reach an idle round")
        }

        func expectWaiting(_ id: NodeID, branch: String, files: [String]) async throws {
            let state = await ledger.workingState()
            let node = try #require(state.nodes[id])
            #expect(state.attentionList.contains { $0.node.id == id },
                    "The conflicted requirement must be waiting for a person in ledger-derived attention")
            let ticket = try #require(await tracker.ticket(node.ticket))
            #expect(ticket.status == state.status(of: node))
            #expect(ticket.comments.contains { comment in
                let text = comment.text.lowercased()
                return comment.text.contains(branch) && files.allSatisfy(comment.text.contains)
                    && (text.contains("human") || text.contains("person"))
            }, "The requirement's ticket must explain the branch, conflicting files and need for a person")
        }
    }

    actor Branches: Workspace, RequirementBranchRepository {
        struct MergeCall: Sendable { let main: String; let branch: String }
        struct RebaseCall: Sendable { let leaf: NodeID; let branch: String; let tip: String }
        struct Commit: Sendable { let parents: [String]; let files: [String] }
        nonisolated let root: URL
        nonisolated let defaultBranch = "main"
        private var refs = ["main": "base"]
        private var commits = ["base": Commit(parents: [], files: [])]
        private var owners: [NodeID: String] = [:]
        private var requirementCheckouts: [URL: String] = [:]
        private var conflicts: [String: [String: [String]]] = [:]
        private var leafConflicts: [NodeID: [String]] = [:]
        private var counter = 0
        private(set) var mergeCalls: [MergeCall] = []
        private(set) var rebaseCalls: [RebaseCall] = []
        private(set) var resetCalls: [NodeID] = []

        init(root: URL) { self.root = root }
        nonisolated func requirementBranch(for ticket: String) -> String { "agentos/\(ticket)" }
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        nonisolated var testArea: String { "Tests/" }
        nonisolated var agentContext: String { "" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated func existingComponents() -> [String] { [] }

        func addRequirement(_ ticket: String) throws {
            let branch = requirementBranch(for: ticket)
            let main = try requiredTip(defaultBranch)
            refs[branch] = commit(parents: [main], files: [])
        }
        func addLeaf(_ id: NodeID, requirement: String, files: [String]) throws {
            let branch = requirementBranch(for: requirement)
            let tip = try requiredTip(branch)
            owners[id] = branch
            refs[self.branch(for: id)] = commit(parents: [tip], files: files)
        }
        func advanceMain(to tip: String, files: [String], including other: [String] = []) {
            commits[tip] = Commit(parents: (refs[defaultBranch].map { [$0] } ?? []) + other, files: files)
            refs[defaultBranch] = tip
        }
        func conflict(_ branch: String, with main: String, files: [String]) {
            conflicts[branch, default: [:]][main] = files
        }
        func conflictLeaf(_ id: NodeID, files: [String]) { leafConflicts[id] = files }
        func requirementTip(for id: NodeID) throws -> String {
            try requiredTip(#require(owners[id]))
        }
        func clearCalls() { mergeCalls = []; rebaseCalls = [] }
        func leafTips(_ ids: [NodeID]) -> [NodeID: String] {
            Dictionary(uniqueKeysWithValues: ids.compactMap { id in refs[branch(for: id)].map { (id, $0) } })
        }
        func tip(of branch: String) -> String? { refs[branch] }
        func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
            let wanted = refs[ancestor] ?? ancestor
            let tip = refs[descendant] ?? descendant
            guard commits[wanted] != nil, commits[tip] != nil else {
                Issue.record("Ancestry requested for an unknown fake commit: \(ancestor), \(descendant)")
                return false
            }
            var pending = [tip]
            var seen = Set<String>()
            while let next = pending.popLast() {
                if next == wanted { return true }
                if seen.insert(next).inserted { pending += commits[next]?.parents ?? [] }
            }
            return false
        }
        func mergeMain(_ main: String, into branch: String) throws -> RebaseResult {
            mergeCalls.append(MergeCall(main: main, branch: branch))
            let old = try requiredTip(branch)
            if isAncestor(main, of: old) { return .clean }
            if let files = conflicts[branch]?[main] { return .conflict(files: files) }
            refs[branch] = isAncestor(old, of: main) ? main : commit(parents: [old, main], files: [])
            return .clean
        }
        func manuallyCatchUp(_ branch: String, to main: String) throws -> String {
            let old = try requiredTip(branch)
            let tip = commit(parents: [old, main], files: [])
            refs[branch] = tip
            return tip
        }
        func changedFiles(in commit: String) throws -> [String] {
            try #require(commits[commit], "Unknown fake commit \(commit)").files
        }
        func prepare() async throws {}
        func requirementWorktree(for requirement: NodeIdentity) throws -> URL {
            let branch = requirementBranch(for: requirement.ticketKey)
            _ = try requiredTip(branch)
            let directory = root.appending(path: "requirements/\(requirement.nodeID)")
            requirementCheckouts[directory] = branch
            owners[requirement.nodeID] = branch
            return directory
        }
        func requirementIsMerged(_ requirement: NodeIdentity) throws -> Bool {
            try isAncestor(requiredTip(requirementBranch(for: requirement.ticketKey)), of: requiredTip(defaultBranch))
        }
        func createWorktree(for id: NodeID) async throws -> URL { worktree(for: id) }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            nil
        }
        func head(of directory: URL) throws -> String {
            try requiredTip(requirementCheckouts[directory] ?? branch(for: directory.lastPathComponent))
        }
        func changedFiles(in directory: URL) throws -> [String] { try changedFiles(in: head(of: directory)) }
        func rebaseOntoMain(_ directory: URL) throws -> RebaseResult {
            let id = directory.lastPathComponent
            let branch = try #require(owners[id], "Every fake leaf must have a requirement")
            let tip = try requiredTip(branch)
            rebaseCalls.append(RebaseCall(leaf: id, branch: branch, tip: tip))
            if let files = leafConflicts[id] { return .conflict(files: files) }
            let old = try head(of: directory)
            refs[self.branch(for: id)] = try commit(parents: [tip], files: changedFiles(in: old))
            return .clean
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) throws {
            let id = directory.lastPathComponent
            resetCalls.append(id)
            refs[branch(for: id)] = try commit(parents: [requirementTip(for: id)], files: [])
            leafConflicts.removeValue(forKey: id)
        }
        func landOnMain(_ id: NodeID) throws -> String {
            let owner = try #require(owners[id])
            let tip = try requiredTip(branch(for: id))
            let previous = try requiredTip(owner)
            try #require(isAncestor(previous, of: tip), "A fake landing must not discard earlier landed work")
            refs[owner] = tip
            return tip
        }
        func prepareBuild(in directory: URL) async throws {}
        private func requiredTip(_ branch: String) throws -> String {
            try #require(refs[branch], "Unknown fake branch \(branch)")
        }
        private func commit(parents: [String], files: [String]) -> String {
            counter += 1
            let id = "commit-\(counter)"
            commits[id] = Commit(parents: parents, files: files)
            return id
        }
    }

    actor Tracker: TrackerAdapter {
        private var tickets: [String: Ticket] = [:]
        private var closed: Set<String> = []
        func add(_ ticket: Ticket) { tickets[ticket.key] = ticket }
        func closeByPerson(_ ticket: String) { closed.insert(ticket) }
        func pendingSignals() -> [AgentOSCore.Signal] { [] }
        func ticket(_ key: String) -> Ticket? { tickets[key] }
        func consume(_ signal: AgentOSCore.Signal, reply: String) { Issue.record("No human signal is needed") }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("GH-89 seeds its work tree")
        }
        func comment(on key: String, _ text: String) {
            tickets[key]?.comments.append(Comment(author: .reconciler, text: text))
        }
        func setStatus(of key: String, to status: String) { tickets[key]?.status = status }
        func isClosed(_ key: String) -> Bool { closed.contains(key) }
    }

    actor Agents: Decomposer, TestAuthor, AgentOSCore.Implementer {
        private(set) var starts: [NodeID] = []
        private var held: (NodeID, Gate)?
        func hold(_ id: NodeID, at gate: Gate) { held = (id, gate) }
        nonisolated var team: AgentTeam {
            AgentTeam(name: "GH-89", decomposer: self, testAuthor: self, implementer: self)
        }
        func proposeChildren(_ request: BreakdownRequest) throws -> Breakdown {
            throw AgentFailure("GH-89 seeds its breakdown")
        }
        func writeAcceptanceTests(_ task: AgentTask) throws -> AgentReport {
            throw AgentFailure("GH-89 seeds fixed acceptance tests")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            starts.append(task.spec.id)
            if let (id, gate) = held, id == task.spec.id {
                try await gate.pause()
                return AgentReport(alreadySatisfied: true)
            }
            return AgentReport(questions: [AgentQuestion(question: "Fixture implementer has started \(task.spec.id)")])
        }
    }
    struct External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
    struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }
    actor Checks: CheckRunner {
        struct Observation: Sendable {
            let leaf: NodeID
            let selection: String?
            let tip: String
            let requirementTip: String
        }
        let workspace: Branches
        private(set) var observations: [Observation] = []
        private var held: (NodeID, Bool, Gate)?
        init(workspace: Branches) { self.workspace = workspace }
        func hold(_ id: NodeID, ownSuite: Bool, at gate: Gate) { held = (id, ownSuite, gate) }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            do {
                let id = directory.lastPathComponent
                let tip = try await workspace.head(of: directory)
                let requirementTip = try await workspace.requirementTip(for: id)
                observations.append(Observation(leaf: id, selection: testTarget, tip: tip, requirementTip: requirementTip))
                if let (leaf, ownSuite, gate) = held, leaf == id, ownSuite == (testTarget != nil) {
                    try await gate.pause()
                }
                return CheckOutput(passed: true, summary: "Passed", log: "Passed")
            } catch {
                Issue.record(error)
                return CheckOutput(passed: false, summary: "Fixture check failed: \(error)", log: "\(error)")
            }
        }
    }
}
