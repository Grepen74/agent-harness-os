import AgentOSCore
import AgentOSAdapters
import AgentOSTestSupport
import Foundation
import Testing

extension GH_150Tests {
    final class Fixture: Sendable {
        static let id = "wn-GH-150"
        static let ownFolder = "App/Kit/Tests/KitTests/GH_150Tests"
        static let legacy = ownFolder + "/GH_150Legacy.swift"
        static let newOwn = ownFolder + "/Nested/GH_150Additional.swift"
        static let primary = "App/Kit/Tests/KitTests/Landing/GH_150Acceptance.swift"
        static let deleted = "App/Kit/Tests/KitTests/Helpers/GH_150Obsolete.swift"
        static let empty = "App/Kit/Tests/KitTests/Helpers/GH_150Empty.swift"
        static let missing = "App/Kit/Tests/KitTests/Helpers/GH_150Missing.swift"
        static let recordedFiles = [primary, deleted, empty, missing]
        static let other = "App/Kit/Tests/KitTests/Older/GH_149Tests.swift"
        static let unapproved = "App/Kit/Tests/KitTests/Older/GH_148Tests.swift"
        static let featureSibling = "App/Kit/Tests/KitTests/Landing/GH_151Tests.swift"
        static let lookalike = ownFolder + "Extra/Unauthorized.swift"
        static let production = "App/Kit/Sources/Kit/Production.swift"

        let root: URL
        let ledger: Ledger
        let base: [String: String]
        let branch: [String: String]
        let workspace: WorkspaceFake
        let author = Author()
        let reviewer = ReviewSpy()
        let reconciler: Reconciler

        init(recorded: Bool, preflight: any AcceptanceTestPreflight = SkippedAcceptanceTestPreflight()) async throws {
            root = try Files.makeRoot()
            base = [
                Self.other: "func olderExpectationBeforeThisWork() {}\n",
                Self.unapproved: "func anotherWorksUnchangedExpectation() {}\n",
                Self.production: "public func existingImplementation() {}\n",
            ]
            var candidate = base
            candidate[Self.other] = "func olderExpectationUpdatedByThisWork() {}\n"
            candidate[Self.legacy] = "func legacyFolderAcceptanceBody() {}\n"
            candidate[Self.production] = "public func implementationThatMustNotReachTheTestAuthor() {}\n"
            if recorded {
                candidate[Self.primary] = "func completeRecordedAcceptanceBodyNotInTheDiff() {}\n"
                candidate[Self.deleted] = "func completeRecordedHelperBodyNotInTheDiff() {}\n"
                candidate[Self.empty] = ""
            }
            branch = candidate
            workspace = try WorkspaceFake(root: root, base: base, branch: branch)
            ledger = try Ledger()
            let unused = NoWork()
            var team = AgentTeam(name: "GH150", decomposer: unused, testAuthor: author, implementer: unused)
            team.reviewer = reviewer
            var policy = Policy(guesswork: .autonomous)
            policy.review.level = .none
            reconciler = Reconciler(ledger: ledger, tracker: Tracker(), external: unused,
                                    workspace: workspace, artifacts: Artifacts(), checks: unused, team: team,
                                    policy: policy, acceptanceTestPreflight: preflight)
            let spec = NodeSpec(id: Self.id, parent: nil, kind: .leaf, title: "Recorded own tests",
                                intent: "Fix earlier acceptance tests in place",
                                acceptanceCriteria: ["Tests belong to their recorded leaf"], touches: ["Kit"])
            var events: [EventKind] = [
                .nodeCreated(spec: spec, ticket: "GH-150"),
                .runStarted(run: "earlier-author", role: .testAuthor),
                .runFinished(run: "earlier-author", outcome: "acceptance tests committed"),
            ]
            if recorded { events.append(.testsRecorded(files: Self.recordedFiles, suite: spec.testTarget)) }
            events += [
                .otherTestsUpdated(files: [Self.other], digest: Hashing.digest(ofFiles: [Self.other], in: workspace.directory)),
                .reviewRecorded(ReviewRecord(stage: .acceptanceTests,
                                             result: ReviewResult(passed: false, findings: ["Correct the existing tests."]),
                                             commit: "earlier-tests", uiEvidence: nil)),
                .phaseChanged(to: .specified),
            ]
            try await ledger.append(events.map { LedgerEvent(node: Self.id, by: .reconciler, kind: $0) })
        }

        func node() async throws -> NodeState {
            try #require(await ledger.workingState().nodes[Self.id])
        }

        func authorAgain() async throws {
            let node = try await node()
            try await withHangGuard("GH150 test-author re-run") {
                _ = try await self.reconciler.authorTests(node)
            }
        }

        func review(_ stage: ReviewStage, changed: [String]) async throws -> ReviewRequest {
            await workspace.setReviewFiles(changed)
            let context = try await workspace.reviewContext(in: workspace.directory, against: "main")
            let node = try await node()
            try await withHangGuard("GH150 \(stage.rawValue) review") {
                _ = try await self.reconciler.review(node, stage: stage, context: context,
                                                    in: self.workspace.directory, run: "review-run")
            }
            return try #require(await reviewer.requests.last)
        }

        func cleanUp() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Cannot remove GH150 fixture: \(error)") }
        }
    }

    enum Files {
        static func makeRoot() throws -> URL {
            var package = URL(filePath: #filePath).deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: package.appending(path: "Package.swift").path) {
                guard package.path != "/" else { throw AgentFailure("Cannot find the fixture's Swift package") }
                package.deleteLastPathComponent()
            }
            let root = package.appending(path: ".build/GH150-fixtures/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        static func write(_ text: String, at path: String, in root: URL) throws {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        static func read(in root: URL) throws -> [String: String] {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            ) else { throw AgentFailure("Cannot enumerate fixture files") }
            var result: [String: String] = [:]
            let prefix = root.standardizedFileURL.path + "/"
            for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let path = String(file.standardizedFileURL.path.dropFirst(prefix.count))
                result[path] = try String(contentsOf: file, encoding: .utf8)
            }
            return result
        }

        static func matches(_ file: String, paths: [String]) -> Bool {
            paths.contains { file == $0 || file.hasPrefix($0 + "/") }
        }

        static func replace(_ files: [String: String], in root: URL) throws {
            for path in try read(in: root).keys where files[path] == nil {
                try FileManager.default.removeItem(at: root.appending(path: path))
            }
            for (path, contents) in files { try write(contents, at: path, in: root) }
        }
    }

    actor WorkspaceFake: Workspace {
        nonisolated let directory: URL
        let base: [String: String]
        var branchFiles: [String: String]
        var checkout: [String: String]
        private(set) var committed: [String: String]?
        var reviewFiles: [String]?
        var commitNumber = 0

        init(root: URL, base: [String: String], branch: [String: String]) throws {
            directory = root.appending(path: "worktree")
            self.base = base
            branchFiles = branch
            checkout = branch
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Files.replace(branch, in: directory)
        }

        nonisolated var testArea: String { "App/Kit/Tests/KitTests/" }
        nonisolated var agentContext: String { "" }
        nonisolated func branch(for id: NodeID) -> String { "agentos/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { directory }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "App/Kit/Tests/KitTests/\(spec.testTarget)" }
        nonisolated func existingComponents() -> [String] { [] }
        func prepare() async throws {}
        func createWorktree(for id: NodeID) async throws -> URL {
            try await createWorktree(for: id, keeping: [])
        }
        func createWorktree(for id: NodeID, keeping paths: [String]) async throws -> URL {
            var fresh = base.filter { !Files.matches($0.key, paths: paths) }
            fresh.merge(branchFiles.filter { Files.matches($0.key, paths: paths) }) { _, kept in kept }
            checkout = fresh
            try Files.replace(fresh, in: directory)
            return directory
        }
        func removeWorktree(for id: NodeID) async throws {}
        func discardChanges(keeping paths: [String], in directory: URL) async throws {
            let current = try Files.read(in: directory)
            var kept = checkout.filter { !Files.matches($0.key, paths: paths) }
            kept.merge(current.filter { Files.matches($0.key, paths: paths) }) { _, edited in edited }
            try Files.replace(kept, in: directory)
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            let current = try Files.read(in: directory)
            guard current != checkout else { return nil }
            committed = current
            branchFiles = current
            checkout = current
            commitNumber += 1
            return "tests-\(commitNumber)"
        }
        func head(of directory: URL) async throws -> String { "tests-\(commitNumber)" }
        func changedFiles(in directory: URL) async throws -> [String] {
            Set(branchFiles.keys).union(base.keys).filter { branchFiles[$0] != base[$0] }.sorted()
        }
        func setReviewFiles(_ files: [String]) { reviewFiles = files }
        func reviewContext(in directory: URL, against branch: String) async throws -> ReviewContext {
            let files: [String]
            if let reviewFiles { files = reviewFiles }
            else { files = try await changedFiles(in: directory) }
            return ReviewContext(baseBranch: branch, commit: "tests-\(commitNumber)", fullDiff: "candidate delta",
                                 changedFiles: files, recentChanges: [], uiEvidence: nil)
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { throw AgentFailure("GH150 must not land") }
        func prepareBuild(in directory: URL) async throws {}
    }

    actor Author: TestAuthor {
        typealias Action = @Sendable (AgentTask) async throws -> AgentReport
        var action: Action?
        private(set) var calls = 0
        func configure(_ action: @escaping Action) { self.action = action }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            calls += 1
            guard let action else { throw AgentFailure("No test-author action configured") }
            return try await action(task)
        }
    }

    actor ReviewSpy: Reviewer {
        private(set) var requests: [ReviewRequest] = []
        func review(_ request: ReviewRequest) async throws -> ReviewResult {
            requests.append(request)
            return ReviewResult(passed: true, findings: [])
        }
    }

    private actor Tracker: TrackerAdapter {
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("GH150 must not create tickets")
        }
        func comment(on key: String, _ text: String) async {}
        func setStatus(of key: String, to status: String) async {}
    }

    private struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    private struct NoWork: Decomposer, AgentOSCore.Implementer, CheckRunner, ExternalDependencySource {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH150 must not decompose")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport { throw AgentFailure("GH150 must not implement") }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("GH150 unexpectedly ran implementation checks")
            return CheckOutput(passed: false, summary: "Unexpected implementation checks", log: "")
        }
        func deliveredKeys() async -> Set<String> { [] }
    }
}
