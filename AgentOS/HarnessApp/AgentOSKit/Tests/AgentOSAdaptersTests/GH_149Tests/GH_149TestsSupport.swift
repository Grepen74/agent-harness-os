import Foundation
import Testing
import AgentOSTestSupport
@testable import AgentOSCore

extension GH_149Tests {
    static let nodeID = "wn-GH-149"
    static let rootID = "wn-GH-149-requirement"
    static let ownFolder = "Tests/Acceptance/GH_149Tests"
    static let ownFile = ownFolder + "/GH_149Tests.swift"
    static let emptyFile = ownFolder + "/EmptyHelper.swift"
    static let recordedFiles = [ownFile, emptyFile]
    static let foreignFile = "Tests/Acceptance/GH_149TestsNeighbor/OtherTests.swift"
    static let updatedFile = "Tests/Acceptance/OtherTests/Updated.swift"
    static let ownViolation = "Acceptance tests were changed after they were fixed (not allowed)"
    static let updatedViolation =
        "Other work's tests the acceptance tests updated were changed afterwards (not allowed): " + updatedFile
    // Historical folder encoding: sorted slash-prefixed paths followed by each file's bytes.
    static var legacyDigest: String {
        Hashing.sha256("/EmptyHelper.swift/GH_149Tests.swiftoriginal recorded acceptance test")
    }

    enum Mutation: String, CaseIterable, Sendable {
        case add, change, delete, unreadable
        static let fileChanges: [Self] = [.add, .change, .delete]
    }

    enum Move: String, CaseIterable, Sendable { case rebase, reset, catchUp }
    enum Damage: String, CaseIterable, Sendable { case recorded, updatedOther }
    struct FileEdit: Sendable { let path: String; let contents: String }

    static func withFixture(_ body: @escaping @Sendable (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do {
            try await withHangGuard("GH-149 acceptance scenario") { try await body(fixture) }
        } catch {
            try fixture.cleanup()
            throw error
        }
        try fixture.cleanup()
    }

    struct Fixture: Sendable {
        let root: URL
        let directory: URL
        let ledger: Ledger
        let workspace: TestWorkspace
        let checks = PassingChecks()
        let services = Services()
        let reconciler: Reconciler

        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH_149-\(UUID().uuidString)")
            directory = root.appending(path: "worktree")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ledger = try Ledger()
            workspace = TestWorkspace(directory: directory)
            reconciler = Reconciler(
                ledger: ledger, tracker: services, external: services, workspace: workspace,
                artifacts: services, checks: checks,
                team: AgentTeam(name: "GH-149", decomposer: services, testAuthor: services, implementer: services),
                requirementBranches: workspace)
            let requirement = NodeSpec(
                id: GH_149Tests.rootID, parent: nil, kind: .composite, title: "Test locks",
                intent: "Keep acceptance tests protected across branch movement", acceptanceCriteria: ["Protect tests"])
            let spec = NodeSpec(
                id: GH_149Tests.nodeID, parent: requirement.id, kind: .leaf, title: "Recorded test locks",
                intent: "Lock exactly the recorded test files", acceptanceCriteria: ["Protect recorded files"])
            try await ledger.append([
                LedgerEvent(node: requirement.id, by: .human("Reviewer"),
                            kind: .nodeCreated(spec: requirement, ticket: "GH-149-requirement")),
                LedgerEvent(node: spec.id, by: .human("Reviewer"),
                            kind: .nodeCreated(spec: spec, ticket: "GH-149")),
            ])
            try write(GH_149Tests.ownFile, "original recorded acceptance test")
            try write(GH_149Tests.emptyFile, "")
            await workspace.setChangedFiles(GH_149Tests.recordedFiles)
        }

        func makeReconciler(ledger: Ledger, testAuthor: (any TestAuthor)? = nil) -> Reconciler {
            Reconciler(
                ledger: ledger, tracker: services, external: services, workspace: workspace,
                artifacts: services, checks: checks,
                team: AgentTeam(name: "GH-149 reload", decomposer: services, testAuthor: testAuthor ?? services,
                                implementer: services),
                requirementBranches: workspace)
        }

        func node() async throws -> NodeState {
            try #require(await ledger.workingState().nodes[GH_149Tests.nodeID])
        }

        func append(_ kinds: [EventKind], node id: NodeID = GH_149Tests.nodeID) async throws {
            try await ledger.append(kinds.map { LedgerEvent(node: id, by: .reconciler, kind: $0) })
        }

        func lock(recorded: Bool = true, updated: [String] = [], legacyDigest: String? = nil) async throws {
            if recorded {
                try await append([.testsRecorded(files: GH_149Tests.recordedFiles, suite: "GH_149Tests")])
            }
            let fingerprint: String
            if let legacyDigest {
                fingerprint = legacyDigest
            } else if recorded {
                fingerprint = try await digest()
            } else {
                fingerprint = Hashing.digest(of: directory.appending(path: GH_149Tests.ownFolder))
            }
            try await append([.testsFixed(digest: fingerprint)])
            if !updated.isEmpty {
                try await append([.otherTestsUpdated(
                    files: updated, digest: Hashing.digest(ofFiles: updated, in: directory))])
            }
            try await append([
                .changeSubmitted(run: "implementation", commit: "candidate"),
                .phaseChanged(to: .checking),
            ])
        }

        func digest() async throws -> String {
            await reconciler.testsDigest(try await node(), in: directory)
        }

        func violation() async throws -> String? {
            try await reconciler.protectedTestsViolation(try await node(), in: directory)
        }

        func expectIntact() async throws {
            #expect(try await violation() == nil)
        }

        func precheck() async throws -> Evidence {
            _ = try await reconciler.preCheck(try await node())
            return try #require(await node().evidence.last)
        }

        func move(_ move: Move) async throws {
            switch move {
            case .rebase:
                let result = try await reconciler.rebaseOntoMain(try await node(), in: directory)
                guard case .clean = result else {
                    Issue.record("The controlled workspace must complete its rebase.")
                    return
                }
            case .reset:
                try await reconciler.resetForRework(try await node(), in: directory)
            case .catchUp:
                try await ledger.append([
                    LedgerEvent(node: nil, by: .reconciler, kind: .baselineChecked(Baseline(
                        commit: "new-main", passed: true, summary: "Passed", seconds: 0, log: nil))),
                ])
                let report = await reconciler.retryRequirementCatchUp()
                #expect(report.safeStop == nil)
                let root = try #require(await ledger.workingState().nodes[GH_149Tests.rootID])
                #expect(root.lastCatchUpSuccess?.mainSHA == "new-main")
            }
        }

        func write(_ path: String, _ contents: String) throws {
            let file = directory.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }

        func remove(_ path: String) throws {
            try FileManager.default.removeItem(at: directory.appending(path: path))
        }

        func mutate(_ path: String, using mutation: Mutation) throws {
            switch mutation {
            case .add, .change:
                try write(path, "changed test contents")
            case .delete:
                try remove(path)
            case .unreadable:
                let file = directory.appending(path: path)
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
                #expect(throws: (any Error).self) { try Data(contentsOf: file) }
            }
        }

        func cleanup() throws {
            for path in GH_149Tests.recordedFiles {
                let file = directory.appending(path: path)
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            }
            try FileManager.default.removeItem(at: root)
        }
    }

    actor TestWorkspace: Workspace, RequirementBranchRepository {
        nonisolated let directory: URL
        nonisolated let defaultBranch = "main"
        private var changed: [String] = []
        private var edits: [FileEdit] = []
        private var caughtUp = false
        private var acceptsAcceptanceCommit = false
        private(set) var moves = 0

        init(directory: URL) { self.directory = directory }
        func setChangedFiles(_ files: [String]) { changed = files }
        func setMoveEdits(_ edits: [FileEdit]) { self.edits = edits }
        func allowAcceptanceCommit() { acceptsAcceptanceCommit = true }
        func prepare() {}
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { directory }
        func createWorktree(for id: NodeID) -> URL { directory }
        func removeWorktree(for id: NodeID) throws { throw AgentFailure("Unexpected worktree removal") }
        func commitAll(in directory: URL, message: String, author: String) throws -> String? {
            guard acceptsAcceptanceCommit else {
                throw AgentFailure("The fixture seeds committed states through ledger events.")
            }
            return "acceptance-tests"
        }
        func head(of directory: URL) -> String { "candidate-after-move" }
        func changedFiles(in directory: URL) -> [String] { changed }
        nonisolated var testArea: String { "Tests/Acceptance/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) throws -> RebaseResult { try applyMove(); return .clean }
        func abortRebase(_ directory: URL) throws { throw AgentFailure("Unexpected rebase abort") }
        func resetForRework(_ directory: URL) throws { try applyMove() }
        func landOnMain(_ id: NodeID) throws -> String { throw AgentFailure("Unexpected landing") }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) {}
        nonisolated func requirementBranch(for ticket: String) -> String { "agentos/\(ticket)" }
        func tip(of branch: String) -> String? { branch == defaultBranch ? "new-main" : (caughtUp ? "merged" : "old") }
        func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
            ancestor == descendant || (caughtUp && ancestor == "new-main" && descendant == "merged")
        }
        func mergeMain(_ main: String, into branch: String) -> RebaseResult { caughtUp = true; return .clean }
        func changedFiles(in commit: String) -> [String] { [] }

        private func applyMove() throws {
            for edit in edits {
                let file = directory.appending(path: edit.path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(edit.contents.utf8).write(to: file)
            }
            moves += 1
        }
    }

    actor PassingChecks: CheckRunner {
        private(set) var calls = 0
        func runChecks(in directory: URL, only testTarget: String?) -> CheckOutput {
            calls += 1
            return CheckOutput(passed: true, summary: "Passed acceptance checks", log: "Passed acceptance checks")
        }
    }

    struct AcceptanceAuthor: TestAuthor {
        func writeAcceptanceTests(_ task: AgentTask) throws -> AgentReport {
            try Data("authored acceptance test".utf8).write(to: task.directory.appending(path: GH_149Tests.ownFile))
            try Data().write(to: task.directory.appending(path: GH_149Tests.emptyFile))
            return AgentReport()
        }
    }

    struct Services: TrackerAdapter, ExternalDependencySource, ArtifactStore, Decomposer, TestAuthor, Implementer {
        func pendingSignals() -> [Signal] { [] }
        func ticket(_ key: String) -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("Unexpected child-ticket creation")
        }
        func comment(on key: String, _ text: String) {}
        func setStatus(of key: String, to status: String) {}
        func deliveredKeys() -> Set<String> { [] }
        func put(named name: String, contents: Data) -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
        func proposeChildren(_ request: BreakdownRequest) throws -> Breakdown {
            throw AgentFailure("Unexpected decomposition")
        }
        func writeAcceptanceTests(_ task: AgentTask) throws -> AgentReport {
            throw AgentFailure("Acceptance tests are already seeded")
        }
        func implement(_ task: AgentTask) throws -> AgentReport { throw AgentFailure("Unexpected implementation") }
    }
}
