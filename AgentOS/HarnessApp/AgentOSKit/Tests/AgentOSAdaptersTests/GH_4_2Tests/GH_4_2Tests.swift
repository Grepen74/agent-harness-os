// API contract: CatchUpCoordinator reconciles agentos/main to a passed main baseline through the shared
// LandingQueue, validates the proposed result before moving the ref, records the reconciliation, and returns
// the repository banner and scan finding shown to users.

import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

@Suite
struct GH_4_2Tests {
    @Test
    func catchUpWaitsForAPassedBaselineAndRunsSeriallyWithLanding() async throws {
        let fixture = try await Fixture()
        _ = try await fixture.commit(on: "agentos/main", file: "landed.txt", contents: "landed\n")
        let target = try await fixture.commit(on: "main", file: "upstream.txt", contents: "upstream\n")
        let probe = ConcurrencyProbe()

        async let landing: Void = fixture.queue.runLanding {
            await probe.enter("landing")
            try await Task.sleep(for: .milliseconds(100))
            await probe.leave()
        }
        while await !probe.hasEntered("landing") {
            try await Task.sleep(for: .milliseconds(5))
        }
        async let catchUp = fixture.coordinator.catchUp(
            after: Baseline(commit: target, passed: true, summary: "passed", seconds: 1, log: nil)
        ) { _ in
            await probe.enter("catch-up")
            await probe.leave()
            return true
        }

        _ = try await (landing, catchUp)
        #expect(await probe.peak == 1)
        #expect(await probe.order == ["landing", "catch-up"])

        let beforeFailure = try await fixture.revision("agentos/main")
        let failed = Baseline(commit: target, passed: false, summary: "failed", seconds: 1, log: nil)
        let result = try await fixture.coordinator.catchUp(after: failed) { _ in
            Issue.record("Acceptance tests must not run after a failed baseline")
            return true
        }
        #expect(result == nil)
        #expect(try await fixture.revision("agentos/main") == beforeFailure)
    }

    @Test
    func rebasesWhenNoneOfTheLandedCommitsAreOnMain() async throws {
        let fixture = try await Fixture()
        let oldLanded = try await fixture.commit(on: "agentos/main", file: "landed.txt", contents: "landed\n")
        let target = try await fixture.commit(on: "main", file: "upstream.txt", contents: "upstream\n")

        let outcome = try #require(try await fixture.catchUp(to: target))

        #expect(outcome.method == .rebase)
        #expect(outcome.commitMappings[oldLanded] != nil)
        #expect(outcome.commitMappings[oldLanded] != oldLanded)
    }

    @Test(arguments: [Representation.reachable, .equivalentPatch, .identicalTree])
    func movesToMainWhenAllLandedWorkIsRepresented(_ representation: Representation) async throws {
        let fixture = try await Fixture()
        let landed = try await fixture.commit(on: "agentos/main", file: "feature.txt", contents: "feature\n")
        try await fixture.representOnMain(landed, as: representation)
        let target = try await fixture.revision("main")

        let outcome = try #require(try await fixture.catchUp(to: target))

        #expect(outcome.method == .move)
        #expect(outcome.newLandingTip == target)
        #expect(try await fixture.revision("agentos/main") == target)
    }

    @Test
    func mergesMainWhenOnlySomeLandedCommitsAreRepresented() async throws {
        let fixture = try await Fixture()
        let represented = try await fixture.commit(on: "agentos/main", file: "one.txt", contents: "one\n")
        let remaining = try await fixture.commit(on: "agentos/main", file: "two.txt", contents: "two\n")
        try await fixture.cherryPick(represented, onto: "main")
        let target = try await fixture.commit(on: "main", file: "upstream.txt", contents: "upstream\n")

        let outcome = try #require(try await fixture.catchUp(to: target))

        #expect(outcome.method == .merge)
        #expect(outcome.commitMappings.isEmpty)
        #expect(try await fixture.isAncestor(remaining, of: outcome.newLandingTip))
    }

    @Test
    func failingAcceptanceTestsLeaveAgentOSMainUnchanged() async throws {
        let fixture = try await Fixture()
        _ = try await fixture.commit(on: "agentos/main", file: "landed.txt", contents: "landed\n")
        let oldTip = try await fixture.revision("agentos/main")
        let target = try await fixture.commit(on: "main", file: "upstream.txt", contents: "upstream\n")
        let proposedResultWasTested = ValueBox(false)

        let outcome = try await fixture.coordinator.catchUp(after: fixture.passedBaseline(target)) { directory in
            let hasLanded = FileManager.default.fileExists(atPath: directory.appending(path: "landed.txt").path)
            let hasUpstream = FileManager.default.fileExists(atPath: directory.appending(path: "upstream.txt").path)
            await proposedResultWasTested.set(hasLanded && hasUpstream)
            return false
        }

        #expect(outcome == nil)
        #expect(await proposedResultWasTested.value)
        #expect(try await fixture.revision("agentos/main") == oldTip)
    }

    @Test
    func successfulCatchUpContainsTheTargetAndAllLandedWork() async throws {
        let fixture = try await Fixture()
        let landed = try await fixture.commit(on: "agentos/main", file: "landed.txt", contents: "landed\n")
        let target = try await fixture.commit(on: "main", file: "upstream.txt", contents: "upstream\n")

        let outcome = try #require(try await fixture.catchUp(to: target))

        #expect(try await fixture.isAncestor(target, of: outcome.newLandingTip))
        let mappedLanded = outcome.commitMappings[landed] ?? landed
        #expect(try await fixture.isAncestor(mappedLanded, of: outcome.newLandingTip))
        #expect(try await fixture.file("landed.txt", at: "agentos/main") == "landed")
        #expect(try await fixture.file("upstream.txt", at: "agentos/main") == "upstream")
    }

    @Test
    func ledgerRecordsTipsTargetMethodAndEveryRebasedCommitMapping() async throws {
        let fixture = try await Fixture()
        let first = try await fixture.commit(on: "agentos/main", file: "one.txt", contents: "one\n")
        let second = try await fixture.commit(on: "agentos/main", file: "two.txt", contents: "two\n")
        let oldTip = try await fixture.revision("agentos/main")
        let target = try await fixture.commit(on: "main", file: "upstream.txt", contents: "upstream\n")

        let outcome = try #require(try await fixture.catchUp(to: target))
        let event = try #require(await fixture.ledger.allRecords().last)
        guard case .caughtUp(
            let recordedTarget,
            let recordedOldTip,
            let recordedNewTip,
            let method,
            let mappings
        ) = event.event.kind else {
            Issue.record("Expected a caughtUp ledger event")
            return
        }

        #expect(recordedTarget == target)
        #expect(recordedOldTip == oldTip)
        #expect(recordedNewTip == outcome.newLandingTip)
        #expect(method == .rebase)
        #expect(mappings == outcome.commitMappings)
        #expect(Set(mappings.keys) == [first, second])
    }

    @Test
    func bannerAndScanNameTheTargetAndMethod() async throws {
        let fixture = try await Fixture()
        _ = try await fixture.commit(on: "agentos/main", file: "landed.txt", contents: "landed\n")
        let target = try await fixture.commit(on: "main", file: "upstream.txt", contents: "upstream\n")

        let outcome = try #require(try await fixture.catchUp(to: target))

        #expect(outcome.status.banner == "agentos/main caught up to \(target) (rebase)")
        #expect(outcome.status.scanFinding.title == "agentos/main caught up to \(target) (rebase)")
        #expect(outcome.status.scanFinding.severity == .info)
    }
}

private extension GH_4_2Tests {
    enum Representation: Sendable {
        case reachable
        case equivalentPatch
        case identicalTree
    }

    final class Fixture: @unchecked Sendable {
        let root: URL
        let workspace: RepositoryWorkspace
        let ledger: Ledger
        let queue: LandingQueue
        let coordinator: CatchUpCoordinator

        init() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "gh-4-2-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "base\n".write(to: root.appending(path: "base.txt"), atomically: true, encoding: .utf8)
            try await Self.git(["init", "-q", "-b", "main"], in: root)
            try await Self.git(["add", "."], in: root)
            try await Self.git(Self.identity + ["commit", "-q", "-m", "base"], in: root)

            let storage = FileManager.default.temporaryDirectory.appending(path: "gh-4-2-storage-\(UUID().uuidString)")
            let config = RepoConfig(
                test: .init(command: "true"),
                leafTests: .init(target: "AgentOSAdaptersTests", folder: "Tests/AgentOSAdaptersTests/")
            )
            let workspace = try RepositoryWorkspace(
                root: root,
                storage: storage,
                config: config,
                landingBranch: "agentos/main",
                defaultBranch: "main"
            )
            try await workspace.prepare()
            let ledger = try Ledger()
            let queue = LandingQueue()
            self.root = root
            self.workspace = workspace
            self.ledger = ledger
            self.queue = queue
            coordinator = CatchUpCoordinator(workspace: workspace, ledger: ledger, landingQueue: queue)
        }

        func passedBaseline(_ target: String) -> Baseline {
            Baseline(commit: target, passed: true, summary: "passed", seconds: 1, log: nil)
        }

        func catchUp(to target: String) async throws -> CatchUpOutcome? {
            try await coordinator.catchUp(after: passedBaseline(target)) { _ in true }
        }

        @discardableResult
        func commit(on branch: String, file: String, contents: String) async throws -> String {
            let directory = FileManager.default.temporaryDirectory.appending(path: "gh-4-2-worktree-\(UUID().uuidString)")
            let old = try await revision(branch)
            try await Self.git(["worktree", "add", "-q", "--detach", directory.path, old], in: root)
            try contents.write(to: directory.appending(path: file), atomically: true, encoding: .utf8)
            try await Self.git(["add", file], in: directory)
            try await Self.git(Self.identity + ["commit", "-q", "-m", file], in: directory)
            let commit = try await Self.git(["rev-parse", "HEAD"], in: directory)
            try await Self.git(["update-ref", "refs/heads/\(branch)", commit, old], in: root)
            try await Self.git(["worktree", "remove", "--force", directory.path], in: root)
            return commit
        }

        func representOnMain(_ commit: String, as representation: Representation) async throws {
            switch representation {
            case .reachable:
                try await merge(commit, onto: "main", squash: false)
            case .equivalentPatch:
                try await cherryPick(commit, onto: "main")
            case .identicalTree:
                try await merge("agentos/main", onto: "main", squash: true)
            }
        }

        func cherryPick(_ commit: String, onto branch: String) async throws {
            let directory = try await detachedWorktree(at: branch)
            try await Self.git(Self.identity + ["cherry-pick", "-q", commit], in: directory)
            try await advance(branch, from: directory)
        }

        func merge(_ commit: String, onto branch: String, squash: Bool) async throws {
            let directory = try await detachedWorktree(at: branch)
            let arguments = Self.identity + ["merge", "-q"] + (squash ? ["--squash"] : ["--no-ff", "-m", "merge"]) + [commit]
            try await Self.git(arguments, in: directory)
            if squash {
                try await Self.git(Self.identity + ["commit", "-q", "-m", "squash"], in: directory)
            }
            try await advance(branch, from: directory)
        }

        func detachedWorktree(at branch: String) async throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appending(path: "gh-4-2-worktree-\(UUID().uuidString)")
            try await Self.git(["worktree", "add", "-q", "--detach", directory.path, branch], in: root)
            return directory
        }

        func advance(_ branch: String, from directory: URL) async throws {
            let old = try await revision(branch)
            let commit = try await Self.git(["rev-parse", "HEAD"], in: directory)
            try await Self.git(["update-ref", "refs/heads/\(branch)", commit, old], in: root)
            try await Self.git(["worktree", "remove", "--force", directory.path], in: root)
        }

        func revision(_ name: String) async throws -> String {
            try await Self.git(["rev-parse", name], in: root)
        }

        func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
            let result = try await ProcessRunner.run(
                "/usr/bin/env",
                ["git", "merge-base", "--is-ancestor", ancestor, descendant],
                in: root
            )
            return result.status == 0
        }

        func file(_ path: String, at revision: String) async throws -> String {
            try await Self.git(["show", "\(revision):\(path)"], in: root)
        }

        static let identity = ["-c", "user.name=Test", "-c", "user.email=test@example.com"]

        @discardableResult
        static func git(_ arguments: [String], in directory: URL) async throws -> String {
            let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
            try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    actor ConcurrencyProbe {
        private(set) var active = 0
        private(set) var peak = 0
        private(set) var order: [String] = []

        func enter(_ operation: String) {
            active += 1
            peak = max(peak, active)
            order.append(operation)
        }

        func leave() {
            active -= 1
        }

        func hasEntered(_ operation: String) -> Bool {
            order.contains(operation)
        }
    }

    actor ValueBox<Value: Sendable> {
        private(set) var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func set(_ value: Value) {
            self.value = value
        }
    }
}
