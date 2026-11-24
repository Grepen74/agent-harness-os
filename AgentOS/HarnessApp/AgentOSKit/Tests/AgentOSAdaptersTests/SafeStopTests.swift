import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

/// A queued change whose worktree had been dirtied by the checks used to stop the whole harness without a trace.
@Suite
struct SafeStopTests {
    @Test
    func aWorktreeThatIsNoLongerCleanEscalatesOnlyItsOwnChangeAndThePeersStillLand() async throws {
        let f = try await GH_104Tests.Fixture(review: .agent)
        defer { f.cleanUp() }
        await f.workspace.makeDirty(f.ids[0])

        try await f.round()

        let dirty = try #require(await f.node(f.ids[0]))
        #expect(dirty.phase == .landing)
        #expect(dirty.landedCommit == nil)
        #expect(dirty.flags[.escalated]?.contains("couldn't read the worktree's status") == true)
        #expect(await f.tracker.comments(on: dirty.ticket).contains {
            $0.contains("Needs a human") && $0.contains("harness:retry")
        })
        try await f.expectPassingBatch([f.ids[1], f.ids[2]])
    }

    @Test
    func aSafeStopIsRecordedOnceAndClearedByTheNextRoundThatRunsWithoutOne() async throws {
        let f = try await GH_104Tests.Fixture(count: 1)
        defer { f.cleanUp() }
        await f.workspace.makeUnavailable(true)

        let stopped = await f.reconciler.runRound(waitForAgents: true)
        _ = await f.reconciler.runRound(waitForAgents: true)

        let reason = try #require(stopped.safeStop)
        #expect(reason.contains("repository is gone"))
        #expect(await f.ledger.workingState().safeStop == reason)
        let records = await f.ledger.allRecords().filter {
            if case .safeStopChanged = $0.event.kind { true } else { false }
        }
        #expect(records.count == 1, "The same stop again must not grow the ledger")
        #expect(records.first?.event.node == nil)

        await f.workspace.makeUnavailable(false)
        try await f.round()

        #expect(await f.ledger.workingState().safeStop == nil)
    }

    @Test
    func checksPutBackTrackedFilesTheyChangedButKeepChangesMadeBeforeThem() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "agentos-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        for (path, text) in ["Generated.txt": "committed\n", "Edited.txt": "committed\n"] {
            try text.write(to: repo.appending(path: path), atomically: true, encoding: .utf8)
        }
        try await Self.git(["init", "-q", "-b", "main"], in: repo)
        try await Self.git(["add", "."], in: repo)
        try await Self.git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"], in: repo)
        try "work in progress\n".write(to: repo.appending(path: "Edited.txt"), atomically: true, encoding: .utf8)
        let runner = CommandCheckRunner(config: RepoConfig(
            build: .init(prepare: "echo regenerated > Generated.txt && echo again >> Edited.txt"),
            test: .init(command: "grep -q regenerated Generated.txt")
        ))

        let output = await runner.runChecks(in: repo, only: nil)

        #expect(output.passed, "The checks must see what the prepare step generated: \(output.log)")
        #expect(try String(contentsOf: repo.appending(path: "Generated.txt"), encoding: .utf8) == "committed\n")
        #expect(try String(contentsOf: repo.appending(path: "Edited.txt"), encoding: .utf8) == "work in progress\nagain\n",
                "A file changed before the checks is not the checks' to put back")
        #expect(output.log.contains("Put back 1 tracked file(s) the checks changed, so the checkout stays as committed: Generated.txt"))
        #expect(try await Self.git(["status", "--porcelain"], in: repo) == "M Edited.txt")
    }

    @Test
    func checksDoNotPutBackAFileWhoseStagedChangeTheWorkingCopyHappensToUndo() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "agentos-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appending(path: "Staged.txt")
        try "committed\n".write(to: file, atomically: true, encoding: .utf8)
        try await Self.git(["init", "-q", "-b", "main"], in: repo)
        try await Self.git(["add", "."], in: repo)
        try await Self.git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"], in: repo)
        try "staged\n".write(to: file, atomically: true, encoding: .utf8)
        try await Self.git(["add", "Staged.txt"], in: repo)
        try "committed\n".write(to: file, atomically: true, encoding: .utf8)
        let runner = CommandCheckRunner(config: RepoConfig(
            build: .init(prepare: "echo regenerated > Staged.txt"), test: .init(command: "true")
        ))

        let output = await runner.runChecks(in: repo, only: nil)

        #expect(output.passed, "\(output.log)")
        #expect(try await Self.git(["show", ":Staged.txt"], in: repo) == "staged",
                "The staged change must survive the checks")
        #expect(!output.log.contains("Put back"))
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
