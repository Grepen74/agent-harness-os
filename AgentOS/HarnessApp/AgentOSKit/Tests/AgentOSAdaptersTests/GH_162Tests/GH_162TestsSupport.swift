import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSCore

extension GH_162Tests {
    static let ownFile = "Tests/Features/SharedSupport.swift"
    static let ownSuite = "FeatureContractTests"
    static let oldFolder = "Tests/AgentOSAdaptersTests/GH_5Tests"
    static let markerFile = "Tests/Features/Contract.swift"
    static let spec = NodeSpec(
        id: "wn-GH-5", parent: nil, kind: .leaf, title: "Reporting work",
        intent: "Route a broken acceptance test", acceptanceCriteria: ["Its owner gets the report"])
    static let otherSpec = NodeSpec(
        id: "wn-GH-53", parent: nil, kind: .leaf, title: "Other work",
        intent: "Own an earlier acceptance test", acceptanceCriteria: ["The earlier contract is checked"])

    final class Fixture: Sendable {
        let directory: URL
        let ledger: Ledger
        let tracker = Tracker()
        let reconciler: Reconciler

        init(recorded: Bool = true, ownFiles: [String] = [GH_162Tests.ownFile],
             ownSuite: String = GH_162Tests.ownSuite, files: [String: String] = [:]) async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "GH_162-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (path, source) in files {
                let url = directory.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try source.write(to: url, atomically: true, encoding: .utf8)
            }
            for path in ownFiles where files[path] == nil {
                let url = directory.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "// Recorded test support\n".write(to: url, atomically: true, encoding: .utf8)
            }
            ledger = try Ledger()
            try await ledger.append([
                LedgerEvent(node: GH_162Tests.spec.id, by: .human("Pat"),
                            kind: .nodeCreated(spec: GH_162Tests.spec, ticket: "GH-5")),
                LedgerEvent(node: GH_162Tests.otherSpec.id, by: .human("Pat"),
                            kind: .nodeCreated(spec: GH_162Tests.otherSpec, ticket: "GH-53")),
            ])
            if recorded {
                try await ledger.append([
                    LedgerEvent(node: GH_162Tests.spec.id, by: .reconciler,
                                kind: .testsRecorded(files: ownFiles, suite: ownSuite)),
                ])
            }
            let stubs = Stubs(directory: directory)
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: stubs, workspace: stubs,
                artifacts: stubs, checks: stubs,
                team: AgentTeam(name: "GH-162", decomposer: stubs, testAuthor: stubs, implementer: stubs))
        }

        func remove() {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Could not remove GH-162 fixture: \(error)") }
        }

        func node() async throws -> NodeState {
            try #require(await ledger.workingState().nodes[GH_162Tests.spec.id])
        }

        func append(_ kinds: [EventKind]) async throws {
            try await ledger.append(kinds.map {
                LedgerEvent(node: GH_162Tests.spec.id, by: .reconciler, kind: $0)
            })
        }

        func recordOther(files: [String], suite: String) async throws {
            try await ledger.append([
                LedgerEvent(node: GH_162Tests.otherSpec.id, by: .reconciler,
                            kind: .testsRecorded(files: files, suite: suite)),
            ])
        }

        func outcomes() async -> [BrokenTestRoutingOutcome] {
            await ledger.records(for: GH_162Tests.spec.id).compactMap {
                guard case .brokenTestRouted(_, let outcome) = $0.event.kind else { return nil }
                return outcome
            }
        }

        func route(_ name: String) async throws {
            try await withHangGuard("routing a GH-162 broken-test report") {
                _ = try await self.reconciler.routeBrokenTest(
                    BrokenTestReport(testName: name, reason: "The test expects the previous contract."),
                    from: try await self.node(), run: "reporting-builder",
                    author: .agent(run: "reporting-builder", role: .implementer), directory: self.directory)
            }
        }

        func expectRouting(_ name: String, own: Bool) async throws {
            try await route(name)
            #expect(await outcomes().last == .sentBackToTestAuthor)
            #expect(try await node().phase == .specified)
            #expect(try await node().flags[.needsInput] == nil)
            let comment = try #require(await tracker.comments.last)
            #expect(comment.contains(name))
            #expect(comment.contains("sent back to the test author"))
            #expect(comment.contains("isn't one of this ticket's tests") == !own)

            // Seed completed automatic returns, not rounds or concurrent agent runs.
            for _ in 1..<Reconciler.automaticTestReturns {
                try await append([
                    .brokenTestReported(BrokenTestReport(testName: name, reason: "The earlier rewrite did not settle it.")),
                    .brokenTestRouted(testName: name, outcome: .sentBackToTestAuthor),
                ])
            }
            try await route(name)
            try await expectWaiting(own: own)
        }

        func expectWaiting(own: Bool) async throws {
            let current = try await node()
            #expect(current.phase == .ready)
            let reason = try #require(current.flags[.needsInput])
            #expect(reason.contains("harness:retry"))
            #expect(reason.contains("isn't one of this ticket's acceptance tests") == !own)
            #expect(await outcomes().last == (own ? .waitingForPerson : .otherTestWaitingForPerson))
            #expect(await reconciler.isWaitingOnOtherTest(current) == !own)
            #expect(await reconciler.isWaitingOnOwnTest(current) == own)
        }

        func oldReport(_ name: String, outcome: BrokenTestRoutingOutcome? = nil) async throws {
            var events: [EventKind] = [
                .runStarted(run: "old-builder", role: .implementer),
                .runFinished(run: "old-builder", outcome: "reported a broken test"),
                .brokenTestReported(BrokenTestReport(testName: name, reason: "The old contract conflicts.")),
            ]
            if let outcome { events.append(.brokenTestRouted(testName: name, outcome: outcome)) }
            events += [.phaseChanged(to: .ready), .flagSet(.needsInput, reason: "Review the test, then add harness:retry.")]
            try await append(events)
        }
    }

    actor Tracker: TrackerAdapter {
        private(set) var comments: [String] = []
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? {
            let spec = key == "GH-5" ? GH_162Tests.spec : GH_162Tests.otherSpec
            return Ticket(key: key, title: spec.title, description: spec.intent,
                          acceptanceCriteria: spec.acceptanceCriteria, createdBy: .human("Pat"))
        }
        func consume(_ signal: Signal, reply: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("Routing tests must not create tickets")
        }
        func comment(on key: String, _ text: String) async { comments.append(text) }
        func setStatus(of key: String, to status: String) async {}
    }

    private struct Stubs: Workspace, ExternalDependencySource, ArtifactStore, CheckRunner,
                          Decomposer, TestAuthor, Implementer {
        let directory: URL
        var testArea: String { "Tests/AgentOSAdaptersTests/" }
        var updatableTestAreas: [String] { [testArea, "Tests/Features/"] }
        var agentContext: String { "" }
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory }
        func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }
        func existingComponents() -> [String] { [] }
        func prepare() async throws {}
        func createWorktree(for id: NodeID) async throws -> URL { directory }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Routing tests must not commit")
        }
        func head(of directory: URL) async throws -> String { "fixture-tip" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func prepareBuild(in directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("Routing tests must not land")
        }
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: false, summary: "Routing tests must not run checks", log: "")
        }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("Routing tests must not decompose work")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Routing tests observe the handoff without running an agent")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Routing tests must not implement work")
        }
    }
}
