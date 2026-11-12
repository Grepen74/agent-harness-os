import Foundation
import Testing
@testable import AgentOSAdapters
import AgentOSCore

@Suite("Catch-up and busy leaves")
struct CatchUpBusyLeavesTests {
    @Test
    func catchUpLeavesTheWorktreesOfLeavesWithAStepInProgressAlone() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "agentos-catchup-busy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "original\n".write(to: repo.appending(path: "base.txt"), atomically: true, encoding: .utf8)
        try await Self.git(["init", "-q", "-b", "main"], in: repo)
        try await Self.git(["add", "."], in: repo)
        try await Self.commit("initial", in: repo)
        let workspace = try RepositoryWorkspace(
            root: repo,
            storage: repo.appending(path: ".storage"),
            config: RepoConfig(test: .init(command: "true"), leafTests: .init(target: "AppTests", folder: "Tests/AppTests")),
            landingBranch: "agentos/main",
            defaultBranch: "main"
        )
        try await workspace.prepare()

        let ledger = try Ledger()
        // idle: nothing running. claimed: its agent recorded runStarted. reserved: scheduled, claim not yet recorded.
        for id in ["idle", "claimed", "reserved"] {
            let directory = try await workspace.createWorktree(for: id)
            try "\(id)\n".write(to: directory.appending(path: "\(id).txt"), atomically: true, encoding: .utf8)
            try #require(try await workspace.commitAll(in: directory, message: "\(id) tests", author: "test-author") != nil)
            let spec = NodeSpec(id: id, parent: nil, kind: .leaf, title: id, intent: "I", acceptanceCriteria: ["a"])
            try await ledger.append([
                LedgerEvent(node: id, by: .human("Alice"), kind: .nodeCreated(spec: spec, ticket: id)),
                LedgerEvent(node: id, by: .reconciler, kind: .testsFixed(digest: "digest")),
                LedgerEvent(node: id, by: .reconciler, kind: .phaseChanged(to: .building)),
            ])
        }
        try await ledger.append([LedgerEvent(node: "claimed", by: .reconciler, kind: .runStarted(run: "run-1", role: .implementer))])

        try "moved\n".write(to: repo.appending(path: "base.txt"), atomically: true, encoding: .utf8)
        try await Self.git(["add", "."], in: repo)
        try await Self.commit("main moved", in: repo)
        let main = try await Self.git(["rev-parse", "main"], in: repo)

        let coordinator = CatchUpCoordinator(workspace: workspace, ledger: ledger, landingQueue: LandingQueue())
        _ = await coordinator.reconcile(busy: ["reserved"])

        #expect(try await Self.isAncestor(main, of: "agentos/main", in: repo))
        #expect(try await Self.isAncestor(main, of: workspace.branch(for: "idle"), in: repo))
        #expect(try await !Self.isAncestor(main, of: workspace.branch(for: "claimed"), in: repo))
        #expect(try await !Self.isAncestor(main, of: workspace.branch(for: "reserved"), in: repo))
        let state = await ledger.workingState()
        #expect(state.nodes["claimed"]?.phase == .building)
        #expect(state.nodes["reserved"]?.phase == .building)
    }

    private static func commit(_ message: String, in repo: URL) async throws {
        try await git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", message], in: repo)
    }

    private static func isAncestor(_ ancestor: String, of descendant: String, in repo: URL) async throws -> Bool {
        try await ProcessRunner.run("/usr/bin/env", ["git", "merge-base", "--is-ancestor", ancestor, descendant], in: repo).status == 0
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
