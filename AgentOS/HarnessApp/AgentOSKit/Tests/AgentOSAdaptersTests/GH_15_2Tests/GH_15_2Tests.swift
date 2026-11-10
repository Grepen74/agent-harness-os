// API contract: RepositorySession reruns landing checks after a no-change landing-failure rework and
// exposes the resulting landing, failed-attempt count, ledger attribution, and ticket explanation.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_15_2Tests {
    @Test
    func noChangeReworkAfterLandingFailureRunsTheFullLandingCheckAgain() async throws {
        let fixture = try await Fixture(landingResults: [.failure, .success])

        await fixture.run()

        #expect(await fixture.checks.fullCheckCount == 2)
        let records = await fixture.session.ledger.allRecords()
        #expect(!records.contains { record in
            if case .attemptFailed(let summary) = record.event.kind {
                return summary.contains("submitted no changes")
            }
            return false
        })
    }

    @Test
    func passingLandingRerunLandsWithoutIncreasingFailedAttempts() async throws {
        let fixture = try await Fixture(landingResults: [.failure, .success])

        await fixture.run()

        let node = try #require(await fixture.node())
        #expect(node.phase == .proven)
        #expect(node.landedCommit != nil)
        #expect(node.failedAttempts == 0)
        #expect(await fixture.ticket().status == "Done")
    }

    @Test
    func repeatedLandingFailureIsAttributedToTheAgentAndCountedOnce() async throws {
        let fixture = try await Fixture(landingResults: [.failure, .failure])

        await fixture.run()

        let node = try #require(await fixture.node())
        #expect(node.failedAttempts == 1)
        #expect(node.phase != .proven)

        let mistakeEvents = await fixture.session.ledger.allRecords().compactMap { record -> String? in
            guard case .attemptFailed(let summary) = record.event.kind else { return nil }
            return summary.contains("agent's own mistake") ? summary : nil
        }
        #expect(mistakeEvents.count == 1)
        #expect(await fixture.ticket().comments.contains {
            $0.text.contains("agent's own mistake")
        })
    }

    @Test
    func noChangesOutsideLandingFailureReworkStillCountsAsAFailedAttempt() async throws {
        let fixture = try await Fixture(
            landingResults: [],
            implementer: NoChangeImplementer()
        )

        await fixture.run()

        let node = try #require(await fixture.node())
        #expect(node.failedAttempts == 1)
        #expect(node.phase != .proven)
        #expect(await fixture.checks.fullCheckCount == 0)
        #expect(node.recentFailures.contains { $0.contains("submitted no changes") })
    }
}

private extension GH_15_2Tests {
    final class Fixture: @unchecked Sendable {
        let session: RepositorySession
        let checks: ScriptedCheckRunner
        let ticketKey: String

        init(
            landingResults: [ScriptedCheckRunner.LandingResult],
            implementer: any AgentOSCore.Implementer = SameChangeImplementer()
        ) async throws {
            let repo = try await Self.makeRepo()
            let storage = FileManager.default.temporaryDirectory
                .appending(path: "gh-15-2-storage-\(UUID().uuidString)")
            let ledger = try Ledger(store: FileLedgerStore(fileURL: storage.appending(path: "ledger.jsonl")))
            let config = RepoConfig(
                test: .init(command: "unused", only: "{suite}"),
                leafTests: .init(target: "AppTests", folder: "Tests/AppTests/")
            )
            var harness = HarnessSettings()
            harness.maxAttempts = 1
            let policy = EffectivePolicy.resolve(harness: harness, repo: config, defaultBranch: "main")
            let location = RepositoryLocation(
                root: repo,
                identity: "gh-15-2",
                branch: "main",
                commit: try await Self.git(["rev-parse", "main"], in: repo)
            )
            checks = ScriptedCheckRunner(landingResults: landingResults)
            session = try RepositorySession(
                location: location,
                storage: storage,
                ledger: ledger,
                config: config,
                policy: policy,
                team: AgentTeam(
                    name: "GH-15.2",
                    decomposer: LeafDecomposer(),
                    testAuthor: AcceptanceTestAuthor(),
                    implementer: implementer
                ),
                checks: checks
            )
            ticketKey = await session.tracker.newTicket(
                title: "Greeting",
                description: "Say hello",
                acceptanceCriteria: ["app.txt says hello"],
                blockedBy: [],
                by: .human("Alice")
            )!.key
            await session.tracker.addLabel("harness:go", to: ticketKey, by: .human("Alice"))
        }

        func run() async {
            await session.runUntilIdle()
        }

        func node() async -> NodeState? {
            await session.ledger.workingState().node(forTicket: ticketKey)
        }

        func ticket() async -> Ticket {
            await session.tracker.ticket(ticketKey)!
        }

        private static func makeRepo() async throws -> URL {
            let repo = FileManager.default.temporaryDirectory
                .appending(path: "gh-15-2-repo-\(UUID().uuidString)")
            let files = [
                "app.txt": "hi\n",
                "AGENTS.md": "# Rules\n",
                "Tests/AppTests/Existing/check.swift": "// existing acceptance test\n",
            ]
            for (path, contents) in files {
                let url = repo.appending(path: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
            try await git(["init", "-q", "-b", "main"], in: repo)
            try await git(["add", "."], in: repo)
            try await git([
                "-c", "user.name=Test",
                "-c", "user.email=test@example.com",
                "commit", "-q", "-m", "Initial",
            ], in: repo)
            return repo
        }

        @discardableResult
        private static func git(_ arguments: [String], in directory: URL) async throws -> String {
            let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
            try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    actor ScriptedCheckRunner: CheckRunner {
        enum LandingResult: Sendable {
            case success
            case failure
        }

        private var landingResults: [LandingResult]
        private(set) var fullCheckCount = 0

        init(landingResults: [LandingResult]) {
            self.landingResults = landingResults
        }

        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            guard testTarget == nil else {
                return CheckOutput(passed: true, summary: "Leaf acceptance tests passed", log: "passed")
            }
            fullCheckCount += 1
            guard !landingResults.isEmpty else {
                return CheckOutput(passed: true, summary: "All tests passed", log: "passed")
            }
            switch landingResults.removeFirst() {
            case .success:
                return CheckOutput(passed: true, summary: "All tests passed", log: "passed")
            case .failure:
                return CheckOutput(
                    passed: false,
                    summary: "Greeting acceptance test failed",
                    log: "Expected app.txt to say hello",
                    failingTargets: ["AppTests"]
                )
            }
        }
    }

    struct LeafDecomposer: Decomposer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            Breakdown(children: [
                ChildProposal(
                    title: request.spec.title,
                    acceptanceCriteria: request.spec.acceptanceCriteria,
                    touches: ["app.txt"]
                ),
            ])
        }
    }

    struct AcceptanceTestAuthor: TestAuthor {
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            let test = task.directory.appending(path: "\(task.testFolder)/GreetingTests.swift")
            try FileManager.default.createDirectory(
                at: test.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "// app.txt must say hello\n".write(to: test, atomically: true, encoding: .utf8)
            return AgentReport()
        }
    }

    struct SameChangeImplementer: AgentOSCore.Implementer {
        func implement(_ task: AgentTask) async throws {
            try "hello\n".write(
                to: task.directory.appending(path: "app.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    struct NoChangeImplementer: AgentOSCore.Implementer {
        func implement(_ task: AgentTask) async throws {}
    }
}
