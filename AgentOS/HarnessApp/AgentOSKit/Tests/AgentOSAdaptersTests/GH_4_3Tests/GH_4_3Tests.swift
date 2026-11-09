// RepositorySession must expose catch-up status, presentation, diff, retry, and terminal-worktree actions.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_4_3Tests {
    private static let config = RepoConfig(
        test: .init(command: "sh run-tests.sh", only: "{suite}"),
        leafTests: .init(target: "AppTests", folder: "Tests/AppTests/")
    )

    struct Leaf: Decomposer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            Breakdown(children: [
                ChildProposal(
                    title: request.spec.title,
                    acceptanceCriteria: request.spec.acceptanceCriteria,
                    touches: ["App"]
                ),
            ])
        }
    }

    struct TestWriter: TestAuthor {
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            let check = task.directory.appending(path: "\(task.testFolder)/check.sh")
            try FileManager.default.createDirectory(at: check.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "true\n".write(to: check, atomically: true, encoding: .utf8)
            return AgentReport()
        }
    }

    struct FileWriter: AgentOSCore.Implementer {
        func implement(_ task: AgentTask) async throws {
            let path: String
            switch task.spec.title {
            case "A work": path = "Sources/A.swift"
            case "Package work": path = "Package.swift"
            default: path = "safe.txt"
            }
            try "agent \(task.spec.title)\n".write(
                to: task.directory.appending(path: path),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    @Test
    func conflictPreservesLandingBranchAndWorkContinuesOnPreviousBase() async throws {
        let fixture = try await conflictingFixture()
        let tipBeforeCatchUp = fixture.agentosTip

        let reports = await fixture.session.runUntilIdle()

        #expect(try await git(["rev-parse", "agentos/main"], in: fixture.repo) == tipBeforeCatchUp)
        #expect(reports.allSatisfy { $0.safeStop == nil })
        let conflict = try #require(catchUpConflicts(in: await fixture.session.ledger.allRecords()).last)
        #expect(conflict.main == fixture.mainSHA)
        #expect(Set(conflict.files) == ["Package.swift", "Sources/A.swift"])
        #expect(Set(conflict.tickets) == [fixture.aTicket, fixture.packageTicket])

        let laterTicket = await createTicket("Safe work", in: fixture.session)
        await fixture.session.runUntilIdle()
        let laterNode = try #require(await fixture.session.ledger.workingState().node(forTicket: laterTicket))
        #expect(laterNode.phase == .proven)
        #expect(try await git(["merge-base", "--is-ancestor", tipBeforeCatchUp, "agentos/main"], in: fixture.repo).isEmpty)
    }

    @Test
    func bannerAndAttentionNameMainFilesTicketsAndActions() async throws {
        let fixture = try await conflictedFixture()

        let status = await fixture.session.catchUpStatus()

        let banner = try #require(status.banner)
        #expect(banner.level == .warning)
        #expect(banner.message.contains("Needs human"))
        #expect(banner.message.contains(fixture.mainSHA))
        #expect(banner.message.contains("Sources/A.swift (\(fixture.aTicket))"))
        #expect(banner.message.contains("Package.swift (\(fixture.packageTicket))"))
        #expect(banner.message.contains("Agents keep working on the previous main"))

        let item = try #require(status.attentionItems.first)
        #expect(item.scope == .repository)
        #expect(item.title == "Catch-up conflict")
        #expect(item.level == .needsHuman)
        #expect(item.message == banner.message)
        #expect(Set(item.actions) == [.showDiff, .retryCatchUp, .openInTerminal])
    }

    @Test
    func scanReportsBehindConflictAsWarning() async throws {
        let fixture = try await conflictedFixture()

        let finding = try #require(await fixture.session.catchUpStatus().scanFinding)

        #expect(finding.severity == .warning)
        #expect(finding.title == "agentos/main is 1 commit behind main: catch-up conflict in 2 files")
    }

    @Test
    func eachRootTicketGetsOnlyItsOwnConflictAndNeedsHumanBoardStatus() async throws {
        let fixture = try await conflictedFixture()

        let a = try #require(await fixture.session.tracker.ticket(fixture.aTicket))
        let package = try #require(await fixture.session.tracker.ticket(fixture.packageTicket))
        let aComments = a.comments.filter { $0.text.contains("Catch-up conflict") }
        let packageComments = package.comments.filter { $0.text.contains("Catch-up conflict") }

        #expect(aComments.count == 1)
        #expect(aComments[0].text.contains(fixture.mainSHA))
        #expect(aComments[0].text.contains("Sources/A.swift"))
        #expect(!aComments[0].text.contains("Package.swift"))
        #expect(packageComments.count == 1)
        #expect(packageComments[0].text.contains(fixture.mainSHA))
        #expect(packageComments[0].text.contains("Package.swift"))
        #expect(!packageComments[0].text.contains("Sources/A.swift"))
        #expect(a.status == "Catch-up conflict")
        #expect(package.status == "Catch-up conflict")
        #expect(await fixture.session.tracker.boardColumn(for: fixture.aTicket) == "Needs human")
        #expect(await fixture.session.tracker.boardColumn(for: fixture.packageTicket) == "Needs human")
    }

    @Test
    func diffAndTerminalWorktreeExposeConflictWithoutChangingDeveloperRefsOrCheckout() async throws {
        let fixture = try await conflictedFixture()
        let checkoutBranch = try await git(["branch", "--show-current"], in: fixture.repo)
        let checkoutStatus = try await git(["status", "--porcelain"], in: fixture.repo)
        let mainBefore = try await git(["rev-parse", "main"], in: fixture.repo)
        let landingBefore = try await git(["rev-parse", "agentos/main"], in: fixture.repo)

        let diff = try await fixture.session.catchUpConflictDiff()
        #expect(diff.contains("Sources/A.swift"))
        #expect(diff.contains("agent A work"))
        #expect(diff.contains("developer A"))
        #expect(diff.contains("Package.swift"))
        #expect(diff.contains("agent Package work"))
        #expect(diff.contains("developer package"))

        let worktree = try await fixture.session.openCatchUpInTerminal()
        #expect(try await git(["rev-parse", "MERGE_HEAD"], in: worktree) == fixture.mainSHA)
        #expect(Set(try await git(["diff", "--name-only", "--diff-filter=U"], in: worktree).split(separator: "\n").map(String.init))
                == ["Package.swift", "Sources/A.swift"])
        #expect(try await git(["branch", "--show-current"], in: fixture.repo) == checkoutBranch)
        #expect(try await git(["status", "--porcelain"], in: fixture.repo) == checkoutStatus)
        #expect(try await git(["rev-parse", "main"], in: fixture.repo) == mainBefore)
        #expect(try await git(["rev-parse", "agentos/main"], in: fixture.repo) == landingBefore)
    }

    @Test
    func retryIsExplicitForSameMainAndAutomaticAfterMainMovesAgain() async throws {
        let fixture = try await conflictedFixture()
        let initialCount = catchUpConflicts(in: await fixture.session.ledger.allRecords()).count

        await fixture.session.runUntilIdle()
        #expect(catchUpConflicts(in: await fixture.session.ledger.allRecords()).count == initialCount)

        await fixture.session.retryCatchUp()
        await fixture.session.runUntilIdle()
        #expect(catchUpConflicts(in: await fixture.session.ledger.allRecords()).count == initialCount + 1)

        try "another main change\n".write(
            to: fixture.repo.appending(path: "main-only.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await commit("main moves again", in: fixture.repo)
        let laterMain = try await git(["rev-parse", "main"], in: fixture.repo)
        await fixture.session.runUntilIdle()
        let conflicts = catchUpConflicts(in: await fixture.session.ledger.allRecords())
        #expect(conflicts.count == initialCount + 2)
        #expect(conflicts.last?.main == laterMain)
    }

    @Test
    func manuallyResolvedMergeIsRecognizedAsSuccessfulCatchUp() async throws {
        let fixture = try await conflictedFixture()
        let resolution = FileManager.default.temporaryDirectory.appending(path: "agentos-manual-\(UUID().uuidString)")
        _ = try await git(["worktree", "add", "-q", resolution.path, "agentos/main"], in: fixture.repo)
        _ = try? await git(["merge", "--no-edit", "main"], in: resolution)
        try "resolved A\n".write(to: resolution.appending(path: "Sources/A.swift"), atomically: true, encoding: .utf8)
        try "resolved package\n".write(to: resolution.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "Sources/A.swift", "Package.swift"], in: resolution)
        _ = try await git(
            ["-c", "user.name=Developer", "-c", "user.email=developer@example.com", "commit", "-q", "--no-edit"],
            in: resolution
        )
        let resolvedTip = try await git(["rev-parse", "HEAD"], in: resolution)
        _ = try await git(["worktree", "remove", resolution.path], in: fixture.repo)

        await fixture.session.runUntilIdle()

        let status = await fixture.session.catchUpStatus()
        #expect(status.lastSuccess?.mainSHA == fixture.mainSHA)
        #expect(status.lastSuccess?.newAgentOSMainTip == resolvedTip)
        #expect(status.lastSuccess?.method == .manual)
        #expect(status.conflict == nil)
    }

    private struct Fixture {
        let repo: URL
        let session: RepositorySession
        let aTicket: String
        let packageTicket: String
        let agentosTip: String
        let mainSHA: String
    }

    private func conflictingFixture() async throws -> Fixture {
        let repo = try await makeRepo()
        let session = try await makeSession(repo)
        let aTicket = await createTicket("A work", in: session)
        await session.runUntilIdle()
        let packageTicket = await createTicket("Package work", in: session)
        await session.runUntilIdle()
        let agentosTip = try await git(["rev-parse", "agentos/main"], in: repo)

        try "developer A\n".write(to: repo.appending(path: "Sources/A.swift"), atomically: true, encoding: .utf8)
        try "developer package\n".write(to: repo.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try await commit("developer changes", in: repo)
        let mainSHA = try await git(["rev-parse", "main"], in: repo)
        return Fixture(
            repo: repo,
            session: session,
            aTicket: aTicket,
            packageTicket: packageTicket,
            agentosTip: agentosTip,
            mainSHA: mainSHA
        )
    }

    private func conflictedFixture() async throws -> Fixture {
        let fixture = try await conflictingFixture()
        await fixture.session.runUntilIdle()
        return fixture
    }

    private func makeSession(_ repo: URL) async throws -> RepositorySession {
        let storage = FileManager.default.temporaryDirectory.appending(path: "agentos-storage-\(UUID().uuidString)")
        let ledger = try Ledger(store: FileLedgerStore(fileURL: storage.appending(path: "ledger.jsonl")))
        let policy = EffectivePolicy.resolve(harness: HarnessSettings(), repo: Self.config, defaultBranch: "main")
        let location = RepositoryLocation(
            root: repo,
            identity: "test",
            branch: "main",
            commit: try await git(["rev-parse", "main"], in: repo)
        )
        let team = AgentTeam(name: "Catch-up fixtures", decomposer: Leaf(), testAuthor: TestWriter(), implementer: FileWriter())
        return try RepositorySession(
            location: location,
            storage: storage,
            ledger: ledger,
            config: Self.config,
            policy: policy,
            team: team
        )
    }

    private func createTicket(_ title: String, in session: RepositorySession) async -> String {
        let ticket = await session.tracker.newTicket(
            title: title,
            description: "Change the file for \(title)",
            acceptanceCriteria: ["The requested file contains the new value"],
            blockedBy: [],
            by: .human("Alice")
        )!
        await session.tracker.addLabel("harness:go", to: ticket.key, by: .human("Alice"))
        return ticket.key
    }

    private func makeRepo() async throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appending(path: "agentos-catch-up-\(UUID().uuidString)")
        let files = [
            "Sources/A.swift": "base A\n",
            "Package.swift": "base package\n",
            "safe.txt": "base safe\n",
            "run-tests.sh": "for f in Tests/AppTests/*/check.sh; do [ -f \"$f\" ] && sh \"$f\" || exit 1; done\n",
            "Tests/AppTests/Existing/check.sh": "true\n",
        ]
        for (path, contents) in files {
            let file = repo.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        _ = try await git(["init", "-q", "-b", "main"], in: repo)
        _ = try await git(["add", "."], in: repo)
        try await commit("initial", in: repo)
        return repo
    }

    private func commit(_ message: String, in directory: URL) async throws {
        _ = try await git(["add", "."], in: directory)
        _ = try await git(
            ["-c", "user.name=Developer", "-c", "user.email=developer@example.com", "commit", "-q", "-m", message],
            in: directory
        )
    }

    private struct RecordedConflict {
        let main: String
        let files: [String]
        let tickets: [String]
    }

    private func catchUpConflicts(in records: [RecordedEvent]) -> [RecordedConflict] {
        records.compactMap { record in
            guard case .catchUpConflicted(let main, let files, let tickets) = record.event.kind else { return nil }
            return RecordedConflict(main: main, files: files, tickets: tickets)
        }
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
