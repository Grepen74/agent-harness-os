import Foundation
import Testing
@testable import AgentOSAdapters
import AgentOSCore

/// Real-repo mode end to end on a temp git repo: fake agents, and "tests" that are shell scripts so a run takes
/// seconds. Each leaf's suite is `Tests/AppTests/<Suite>/check.sh`.
@Suite("Repository workspace")
struct RepositoryWorkspaceTests {
    static let runner = """
        if [ -n "$1" ]; then sh "Tests/AppTests/$1/check.sh"; exit $?; fi
        for f in Tests/AppTests/*/check.sh; do [ -f "$f" ] || continue; sh "$f" || exit 1; done
        """

    static let config = RepoConfig(
        test: .init(command: "sh run-tests.sh", only: "{suite}"),
        leafTests: .init(target: "AppTests", folder: "Tests/AppTests/"))

    struct Leaf: Decomposer {
        /// Each ticket's leaf touches a component named after the ticket, so tickets meant to be built side by side
        /// don't overlap; otherwise every leaf touches "App".
        var touchesOwnComponent = false

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            Breakdown(children: [ChildProposal(title: request.spec.title, acceptanceCriteria: request.spec.acceptanceCriteria,
                                               touches: [touchesOwnComponent ? request.spec.title : "App"])])
        }
    }

    struct ShellTestAuthor: TestAuthor {
        /// Builds its tests against placeholder code, as a real test author does: changes a tracked file, deletes one,
        /// adds a new one, and experiments in its scratch folder.
        var writesPlaceholders = false
        /// Each ticket checks a file of its own (`<title>.txt`), so tickets running side by side never make the
        /// same change: otherwise whichever lands last finds nothing left to do, depending on timing.
        var filePerTicket = false
        /// Updates the older `Existing` suite, as a ticket that deliberately changes what it checks does, and lists
        /// it; it also lists a production file, which isn't a test and so must not be kept.
        var updatesExistingTest = false
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            let url = task.directory.appending(path: "\(task.testFolder)/check.sh")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let file = filePerTicket ? "\(task.spec.title).txt" : "app.txt"
            try "grep -q hello '\(file)'\n".write(to: url, atomically: true, encoding: .utf8)
            if writesPlaceholders {
                try "placeholder\n".write(to: task.directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
                try FileManager.default.removeItem(at: task.directory.appending(path: "run-tests.sh"))
                let source = task.directory.appending(path: "Sources/Placeholder.swift")
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "func greeting() -> String { \"\" }\n".write(to: source, atomically: true, encoding: .utf8)
                try "probe\n".write(to: task.scratchDirectory.appending(path: "probe.txt"), atomically: true, encoding: .utf8)
            }
            if updatesExistingTest {
                // Only its first line, as a ticket changing one expectation does.
                let existing = task.directory.appending(path: Self.existing)
                let rest = try String(contentsOf: existing, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                try (["grep -q hello app.txt"] + rest).joined(separator: "\n").write(to: existing, atomically: true, encoding: .utf8)
                try "placeholder\n".write(to: task.directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
                return AgentReport(updatedTests: [Self.existing, "app.txt"])
            }
            return AgentReport()
        }

        static let existing = "Tests/AppTests/Existing/check.sh"
    }

    struct Implementer: AgentOSCore.Implementer {
        var alsoEdits: String?
        var renames: String?
        var runsGit: [String]?
        func implement(_ task: AgentTask) async throws {
            if let runsGit { _ = try await ProcessRunner.run("/usr/bin/env", ["git"] + runsGit, in: task.directory) }
            try "hello\n".write(to: task.directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
            // Build output the repo's .gitignore doesn't cover: must never be committed.
            let build = task.directory.appending(path: ".build/out.o")
            try FileManager.default.createDirectory(at: build.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "binary".write(to: build, atomically: true, encoding: .utf8)
            if let alsoEdits {
                try "changed by an agent\n".write(to: task.directory.appending(path: alsoEdits), atomically: true, encoding: .utf8)
            }
            if let renames, !FileManager.default.fileExists(atPath: task.directory.appending(path: "notes.md").path) {
                try FileManager.default.moveItem(at: task.directory.appending(path: renames), to: task.directory.appending(path: "notes.md"))
            }
        }
    }

    func team(alsoEdits: String? = nil, renames: String? = nil, runsGit: [String]? = nil, authorWritesPlaceholders: Bool = false,
              authorUpdatesExistingTest: Bool = false) -> AgentTeam {
        AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: ShellTestAuthor(
                    writesPlaceholders: authorWritesPlaceholders, updatesExistingTest: authorUpdatesExistingTest),
                  implementer: Implementer(alsoEdits: alsoEdits, renames: renames, runsGit: runsGit))
    }

    func session(_ repo: URL, team: AgentTeam, harness: HarnessSettings = HarnessSettings(),
                 config: RepoConfig = Self.config) async throws -> RepositorySession {
        let storage = FileManager.default.temporaryDirectory.appending(path: "agentos-storage-\(UUID().uuidString)")
        let ledger = try Ledger(store: FileLedgerStore(fileURL: storage.appending(path: "ledger.jsonl")))
        let policy = EffectivePolicy.resolve(harness: harness, repo: config, defaultBranch: "main")
        let location = RepositoryLocation(root: repo, identity: "test", branch: "main", commit: try await git(["rev-parse", "main"], in: repo))
        return try RepositorySession(location: location, storage: storage, ledger: ledger, config: config, policy: policy, team: team)
    }

    func ticket(_ session: RepositorySession, title: String = "Greeting") async -> String {
        let key = await session.tracker.newTicket(
            title: title, description: "Say hello", acceptanceCriteria: ["app.txt says hello"], blockedBy: [], by: .human("Alice"))!.key
        await session.tracker.addLabel("harness:go", to: key, by: .human("Alice"))
        return key
    }

    @Test("A leaf lands on agentos/main; your checkout and main stay as they were")
    func landsOnTheLandingBranchOnly() async throws {
        let repo = try await makeRepo()
        let main = try await git(["rev-parse", "main"], in: repo)
        let session = try await session(repo, team: team())
        let key = await ticket(session)

        let reports = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase == .proven, "\(reports.flatMap(\.actions))")
        #expect(try await git(["show", "agentos/main:app.txt"], in: repo) == "hello")
        #expect(try await git(["rev-parse", "main"], in: repo) == main)
        #expect(try await git(["branch", "--show-current"], in: repo) == "main")
        #expect(try await git(["status", "--porcelain"], in: repo).isEmpty)
        #expect(try String(contentsOf: repo.appending(path: "app.txt"), encoding: .utf8) == "hi\n")
        let landed = try await git(["diff", "--name-only", "main", "agentos/main"], in: repo)
        #expect(landed.split(separator: "\n").sorted() == ["Tests/AppTests/WORK_1Tests/check.sh", "app.txt"])
        #expect(!FileManager.default.fileExists(atPath: session.workspace.worktree(for: node.id).path))
    }

    @Test("The decomposer reads a snapshot of agentos/main that is thrown away afterwards")
    func decomposerReadsASnapshot() async throws {
        let repo = try await makeRepo()
        let seen = Seen()
        let session = try await session(repo, team: AgentTeam(
            name: "Fake", decomposer: SnapshotReader(seen: seen), testAuthor: ShellTestAuthor(), implementer: Implementer()))
        let key = await ticket(session)

        await session.runUntilFinished()

        let snapshot = try #require(await seen.codebase)
        #expect(await seen.instructions?.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        #expect(try await !git(["worktree", "list"], in: repo).contains(snapshot.lastPathComponent))
        #expect(try await session.ledger.workingState().node(forTicket: key)?.phase == .proven)
        #expect(try await !git(["ls-tree", "-r", "--name-only", "agentos/main"], in: repo).contains("stray.txt"))
        #expect(try await git(["status", "--porcelain"], in: repo).isEmpty)
    }

    actor Seen {
        var codebase: URL?
        var instructions: String?
        func record(_ codebase: URL?, _ instructions: String?) { self.codebase = codebase; self.instructions = instructions }
    }

    struct SnapshotReader: Decomposer {
        let seen: Seen
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            let codebase = request.codebase
            await seen.record(codebase, codebase.flatMap { try? String(contentsOf: $0.appending(path: "AGENTS.md"), encoding: .utf8) })
            if let codebase { try "written by the decomposer".write(to: codebase.appending(path: "stray.txt"), atomically: true, encoding: .utf8) }
            return try await Leaf().proposeChildren(request)
        }
    }

    @Test("Changing a protected file fails the check, so nothing lands")
    func protectedPathsAreEnforced() async throws {
        let repo = try await makeRepo()
        let session = try await session(repo, team: team(alsoEdits: "AGENTS.md"))
        let key = await ticket(session)

        await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase != .proven)
        #expect(node.flags[.escalated] != nil)
        #expect(node.recentFailures.first == "Changed protected files (not allowed): AGENTS.md", "\(node.recentFailures)")
        #expect(try await git(["rev-parse", "agentos/main"], in: repo) == git(["rev-parse", "main"], in: repo))
    }

    @Test("Moving a protected file away counts as changing it")
    func renamingAProtectedFileIsCaught() async throws {
        let repo = try await makeRepo()
        let session = try await session(repo, team: team(renames: "AGENTS.md"))
        let key = await ticket(session)

        await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase != .proven)
        #expect(node.recentFailures.first == "Changed protected files (not allowed): AGENTS.md", "\(node.recentFailures)")
        #expect(try await git(["rev-parse", "agentos/main"], in: repo) == git(["rev-parse", "main"], in: repo))
    }

    @Test("Only the test author's tests are committed: the placeholder code it ran them against is thrown away")
    func testAuthorsPlaceholdersAreThrownAway() async throws {
        let repo = try await makeRepo()
        let session = try await session(repo, team: team(authorWritesPlaceholders: true))
        let key = await ticket(session)

        let reports = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase == .proven, "\(node.flags) \(reports.flatMap(\.actions))")
        let tests = try await git(["log", "agentos/main", "--format=%H", "--grep=acceptance tests"], in: repo)
        #expect(try await git(["show", "--name-only", "--format=", tests], in: repo) == "Tests/AppTests/WORK_1Tests/check.sh")
        let landed = try await git(["diff", "--name-only", "main", "agentos/main"], in: repo)
        #expect(landed.split(separator: "\n").sorted() == ["Tests/AppTests/WORK_1Tests/check.sh", "app.txt"])
    }

    @Test("Older tests the test author updates and lists land with its tests; nothing else it lists is kept")
    func testAuthorsUpdatedOlderTestsLand() async throws {
        let repo = try await makeRepo()
        let session = try await session(repo, team: team(authorUpdatesExistingTest: true))
        let key = await ticket(session)

        let reports = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase == .proven, "\(node.flags) \(reports.flatMap(\.actions))")
        #expect(node.updatedOtherTests == [ShellTestAuthor.existing])
        let tests = try await git(["log", "agentos/main", "--format=%H", "--grep=acceptance tests"], in: repo)
        #expect(try await git(["show", "--name-only", "--format=", tests], in: repo).split(separator: "\n").map(String.init).sorted()
                == [ShellTestAuthor.existing, "Tests/AppTests/WORK_1Tests/check.sh"])
        #expect(try await git(["show", "agentos/main:\(ShellTestAuthor.existing)"], in: repo) == "grep -q hello app.txt")
    }

    @Test("Tests in a folder leafTests.updatable names may be updated too; tests elsewhere may not", arguments: [true, false])
    func testsInFurtherUpdatableFoldersLand(listed: Bool) async throws {
        let repo = try await makeRepo()
        var config = Self.config
        config.leafTests?.updatable = listed ? ["./Tests/Unit/", "..", "/elsewhere", "", "Tests/AppTests"] : nil
        let session = try await session(repo, team: AgentTeam(name: "Fake", decomposer: Leaf(),
                                                              testAuthor: UpdatesUnitTest(), implementer: Implementer()), config: config)
        let key = await ticket(session)

        let reports = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase == .proven, "\(node.flags) \(reports.flatMap(\.actions))")
        #expect(node.updatedOtherTests == (listed ? [UpdatesUnitTest.file] : []))
        let landed = try await git(["ls-tree", "-r", "--name-only", "agentos/main", "--", "Tests/Unit"], in: repo)
        #expect(landed == (listed ? UpdatesUnitTest.file : ""))

        let workspace = try RepositoryWorkspace(root: repo, storage: repo, config: config,
                                                landingBranch: "agentos/main", defaultBranch: "main")
        #expect(workspace.updatableTestAreas == (listed ? ["Tests/AppTests/", "Tests/Unit/"] : ["Tests/AppTests/"]))
        #expect(workspace.agentContext.contains("Other work items' existing tests also live in Tests/Unit/.") == listed)
    }

    /// Updates a test of another test target, as a ticket changing what it checks does.
    struct UpdatesUnitTest: TestAuthor {
        static let file = "Tests/Unit/check.sh"
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            let own = task.directory.appending(path: "\(task.testFolder)/check.sh")
            try FileManager.default.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "grep -q hello app.txt\n".write(to: own, atomically: true, encoding: .utf8)
            let other = task.directory.appending(path: Self.file)
            try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "grep -q hello app.txt\n".write(to: other, atomically: true, encoding: .utf8)
            return AgentReport(updatedTests: [Self.file])
        }
    }

    @Test("Older tests the test author updated stay updated when its tests come back from review")
    func updatedOlderTestsSurviveTestsComingBack() async throws {
        let repo = try await makeRepo()
        var team = AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: UpdatesExistingOnce(), implementer: Implementer())
        team.reviewer = FindsFaultOnce()
        let session = try await session(repo, team: team)
        let key = await ticket(session)

        let reports = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase == .proven, "\(node.flags) \(reports.flatMap(\.actions))")
        #expect(node.reviews.contains { $0.stage == .acceptanceTests && !$0.result.passed })
        #expect(node.updatedOtherTests == [ShellTestAuthor.existing])
        #expect(try await git(["show", "agentos/main:\(ShellTestAuthor.existing)"], in: repo) == "grep -q hello app.txt")
    }

    /// Updates the older `Existing` suite on its first run only; the run fixing review findings doesn't list it.
    actor UpdatesExistingOnce: TestAuthor {
        private var runs = 0
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            runs += 1
            let url = task.directory.appending(path: "\(task.testFolder)/check.sh")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "grep -q hello app.txt # run \(runs)\n".write(to: url, atomically: true, encoding: .utf8)
            guard runs == 1 else { return AgentReport() }
            try "grep -q hello app.txt\n".write(to: task.directory.appending(path: ShellTestAuthor.existing), atomically: true, encoding: .utf8)
            return AgentReport(updatedTests: [ShellTestAuthor.existing])
        }
    }

    actor FindsFaultOnce: Reviewer {
        private var found = false
        func review(_ request: ReviewRequest) async throws -> ReviewResult {
            guard request.stage == .acceptanceTests, !found else { return ReviewResult(passed: true, findings: []) }
            found = true
            return ReviewResult(passed: false, findings: ["Name the greeting in the test."])
        }
    }

    @Test("The implementer may not change an older test the test author updated")
    func updatedOlderTestsAreLocked() async throws {
        let repo = try await makeRepo()
        let session = try await session(repo, team: team(alsoEdits: ShellTestAuthor.existing, authorUpdatesExistingTest: true))
        let key = await ticket(session)

        await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase != .proven)
        #expect(node.recentFailures.first?.contains("updated were changed afterwards") == true, "\(node.recentFailures)")
        #expect(try await git(["rev-parse", "agentos/main"], in: repo) == git(["rev-parse", "main"], in: repo))
    }

    @Test("An older test a leaf updated may change on the landing branch meanwhile; the leaf still lands")
    func updatedOlderTestsMayChangeOnTheLandingBranch() async throws {
        let repo = try await makeRepo()
        let existing = ShellTestAuthor.existing
        try "true\n# a\n# b\n# c\n# d\n# e\n".write(to: repo.appending(path: existing), atomically: true, encoding: .utf8)
        try await git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qam", "longer check"], in: repo)
        let session = try await session(repo, team: team(authorUpdatesExistingTest: true))
        let key = await ticket(session)
        var rounds = 0
        while await session.ledger.workingState().node(forTicket: key)?.lastSubmission == nil, rounds < 50 {
            _ = await session.step(waitForAgents: true)
            rounds += 1
        }

        // Other work lands a change to the same test, elsewhere in the file.
        let other = FileManager.default.temporaryDirectory.appending(path: "agentos-other-\(UUID().uuidString)")
        try await git(["worktree", "add", "-q", other.path, "agentos/main"], in: repo)
        try "true\n# a\n# b\n# c\n# d\n# e, landed meanwhile\n".write(to: other.appending(path: existing), atomically: true, encoding: .utf8)
        try await git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qam", "other work"], in: other)
        try await git(["worktree", "remove", "--force", other.path], in: repo)

        await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase == .proven, "\(node.recentFailures)")
        #expect(try await git(["show", "agentos/main:\(existing)"], in: repo)
                == "grep -q hello app.txt\n# a\n# b\n# c\n# d\n# e, landed meanwhile")
    }

    @Test("Putting back the test author's version of an updated older test after main changed it counts as changing it")
    func updatedOlderTestsMayNotDropTheLandingBranchsChange() async throws {
        let repo = try await makeRepo()
        let existing = ShellTestAuthor.existing
        try "true\n# a\n# b\n# c\n# d\n# e\n".write(to: repo.appending(path: existing), atomically: true, encoding: .utf8)
        try await git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qam", "longer check"], in: repo)
        let implementer = RestoresExisting(content: "grep -q hello app.txt\n# a\n# b\n# c\n# d\n# e\n")
        let session = try await session(repo, team: AgentTeam(
            name: "Fake", decomposer: Leaf(), testAuthor: ShellTestAuthor(updatesExistingTest: true), implementer: implementer))
        let key = await ticket(session)
        var rounds = 0
        while await session.ledger.workingState().node(forTicket: key)?.testsDigest == nil, rounds < 50 {
            _ = await session.step(waitForAgents: true)
            rounds += 1
        }
        #expect(await implementer.runs == 0, "main must move before the implementation starts")

        let other = FileManager.default.temporaryDirectory.appending(path: "agentos-other-\(UUID().uuidString)")
        try await git(["worktree", "add", "-q", other.path, "agentos/main"], in: repo)
        try "true\n# a\n# b\n# c\n# d\n# e, landed meanwhile\n".write(to: other.appending(path: existing), atomically: true, encoding: .utf8)
        try await git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qam", "other work"], in: other)
        try await git(["worktree", "remove", "--force", other.path], in: repo)
        let landed = try await git(["rev-parse", "agentos/main"], in: repo)

        await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(await implementer.runs > 0)
        #expect(node.phase != .proven)
        #expect(node.recentFailures.first?.contains("updated were changed afterwards") == true, "\(node.recentFailures)")
        #expect(try await git(["rev-parse", "agentos/main"], in: repo) == landed)
    }

    @Test("An implementer's uncommitted change to an updated older test, thrown away when it asks, doesn't stop the lock moving")
    func discardedChangesDontKeepTheLockBehind() async throws {
        let repo = try await makeRepo()
        let existing = ShellTestAuthor.existing
        try "true\n# a\n# b\n# c\n# d\n# e\n".write(to: repo.appending(path: existing), atomically: true, encoding: .utf8)
        try await git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qam", "longer check"], in: repo)
        let session = try await session(repo, team: AgentTeam(
            name: "Fake", decomposer: Leaf(), testAuthor: ShellTestAuthor(updatesExistingTest: true),
            implementer: AsksOnceWhileMainMoves(repo: repo)))
        let key = await ticket(session)
        var rounds = 0
        while await session.ledger.workingState().node(forTicket: key)?.openQuestions.isEmpty != false, rounds < 50 {
            _ = await session.step(waitForAgents: true)
            rounds += 1
        }

        await session.tracker.addComment("1. Answer: Say hello", to: key, by: .human("Alice"))
        await session.tracker.addLabel(HarnessCommand.retry.label, to: key, by: .human("Alice"))
        await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase == .proven, "\(node.recentFailures) \(node.flags)")
        #expect(try await git(["show", "agentos/main:\(existing)"], in: repo)
                == "grep -q hello app.txt\n# a\n# b\n# c\n# d\n# e, landed meanwhile")
    }

    /// First run: other work lands a change to the older `Existing` suite meanwhile, and the implementer, having
    /// started on that suite, asks a question. Later runs implement.
    actor AsksOnceWhileMainMoves: AgentOSCore.Implementer {
        let repo: URL
        private var asked = false
        init(repo: URL) { self.repo = repo }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            guard !asked else {
                try "hello\n".write(to: task.directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
                return AgentReport()
            }
            asked = true
            let existing = ShellTestAuthor.existing
            let other = FileManager.default.temporaryDirectory.appending(path: "agentos-other-\(UUID().uuidString)")
            let commit = ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qam", "other work"]
            _ = try await ProcessRunner.run("/usr/bin/env", ["git", "worktree", "add", "-q", other.path, "agentos/main"], in: repo)
            try "true\n# a\n# b\n# c\n# d\n# e, landed meanwhile\n".write(to: other.appending(path: existing), atomically: true, encoding: .utf8)
            _ = try await ProcessRunner.run("/usr/bin/env", ["git"] + commit, in: other)
            _ = try await ProcessRunner.run("/usr/bin/env", ["git", "worktree", "remove", "--force", other.path], in: repo)
            try "started\n".write(to: task.directory.appending(path: existing), atomically: true, encoding: .utf8)
            return AgentReport(questions: [AgentQuestion(question: "Which greeting?")])
        }
    }

    /// Implements, and puts back the given content of the older `Existing` suite.
    actor RestoresExisting: AgentOSCore.Implementer {
        let content: String
        private(set) var runs = 0
        init(content: String) { self.content = content }
        func implement(_ task: AgentTask) async throws {
            runs += 1
            try "hello\n".write(to: task.directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
            try content.write(to: task.directory.appending(path: ShellTestAuthor.existing), atomically: true, encoding: .utf8)
        }
    }

    @Test("An agent that changes your refs or git config is escalated, not retried", arguments: [
        (["tag", "sneaky"], "refs/tags/sneaky"),
        (["update-ref", "refs/remotes/origin/main", "HEAD"], "refs/remotes/origin/main"),
        (["config", "user.name", "Mallory"], "config"),
    ])
    func agentsMayNotTouchYourGitState(command: [String], named: String) async throws {
        let repo = try await makeRepo()
        let session = try await session(repo, team: team(runsGit: command))
        let key = await ticket(session)

        await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase != .proven)
        #expect(node.failedAttempts == 1, "escalated straight away")
        #expect(node.flags[.escalated]?.contains("changed your repo outside agentos/: \(named)") == true, "\(node.flags)")
        #expect(try await git(["rev-parse", "agentos/main"], in: repo) == git(["rev-parse", "main"], in: repo))
    }

    /// Counts implementers at work. Each one waits until as many are at work as the harness may run at once (or
    /// as are left), so the peak doesn't depend on how long agents take or how rounds are scheduled. If that
    /// never happens it gives up after a while, so the test fails instead of hanging.
    actor Workbench {
        let limit: Int
        let total: Int
        private(set) var busy = 0
        private(set) var peak = 0
        private var finished = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(limit: Int, total: Int) { self.limit = limit; self.total = total }

        func start() async {
            busy += 1
            peak = max(peak, busy)
            if releaseIfMet() { return }
            let timeout = Task { try await Task.sleep(for: .seconds(20)); self.releaseAll() }
            await withCheckedContinuation { waiters.append($0) }
            timeout.cancel()
        }

        func stop() {
            busy -= 1
            finished += 1
            _ = releaseIfMet()
        }

        private func releaseIfMet() -> Bool {
            guard busy >= min(limit, total - finished) else { return false }
            releaseAll()
            return true
        }

        private func releaseAll() {
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    struct WorkbenchImplementer: AgentOSCore.Implementer {
        let bench: Workbench
        func implement(_ task: AgentTask) async throws {
            await bench.start()
            try "hello\n".write(to: task.directory.appending(path: "\(task.spec.title).txt"), atomically: true, encoding: .utf8)
            await bench.stop()
        }
    }

    @Test("Leaves are built side by side, up to the max parallel agents", arguments: [1, 2])
    func buildsInParallelUpToTheLimit(limit: Int) async throws {
        let repo = try await makeRepo()
        let bench = Workbench(limit: limit, total: 3)
        var harness = HarnessSettings()
        harness.maxParallelAgents = limit
        let team = AgentTeam(name: "Side by side", decomposer: Leaf(touchesOwnComponent: true), testAuthor: ShellTestAuthor(filePerTicket: true),
                             implementer: WorkbenchImplementer(bench: bench))
        let session = try await session(repo, team: team, harness: harness)
        let keys = [await ticket(session, title: "One"), await ticket(session, title: "Two"), await ticket(session, title: "Three")]

        let reports = await session.runUntilFinished()

        let state = await session.ledger.workingState()
        for key in keys { #expect(state.node(forTicket: key)?.phase == .proven, "\(reports.flatMap(\.actions))") }
        #expect(await bench.peak == limit)
    }

    /// Named moments agents wait for, so "while the other agent is still at work" is arranged, not hoped for.
    /// Waiting gives up after a while, so the test fails instead of hanging.
    actor Moments {
        private var reached: Set<String> = []
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func reach(_ moment: String) {
            reached.insert(moment)
            for waiter in waiters.removeValue(forKey: moment) ?? [] { waiter.resume() }
        }

        func wait(for moment: String) async {
            guard !reached.contains(moment) else { return }
            let timeout = Task { try await Task.sleep(for: .seconds(20)); self.reach(moment) }
            await withCheckedContinuation { waiters[moment, default: []].append($0) }
            timeout.cancel()
        }
    }

    /// "Sneaky" tags the repo behind the harness's back while "Honest" is still at work.
    struct TaggingImplementer: AgentOSCore.Implementer {
        let moments: Moments
        func implement(_ task: AgentTask) async throws {
            if task.spec.title == "Sneaky" {
                await moments.wait(for: "honest started")
                _ = try await ProcessRunner.run("/usr/bin/env", ["git", "tag", "sneaky"], in: task.directory)
                await moments.reach("tagged")
            } else {
                await moments.reach("honest started")
                await moments.wait(for: "tagged")
            }
            try "hello\n".write(to: task.directory.appending(path: "\(task.spec.title).txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Holds an implementer midway until the test lets it go.
    actor Pause {
        private(set) var reached = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            reached = true
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { waiter?.resume() }
    }

    struct HalfwayImplementer: AgentOSCore.Implementer {
        let pause: Pause
        func implement(_ task: AgentTask) async throws {
            AgentLog.append("Writing app.txt", to: task.log)
            try "hello\n".write(to: task.directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
            try "draft\n".write(to: task.directory.appending(path: "draft.txt"), atomically: true, encoding: .utf8)
            await pause.wait()
            try FileManager.default.removeItem(at: task.directory.appending(path: "draft.txt"))
            AgentLog.append("Done", to: task.log)
        }
    }

    @Test("While an agent works you can follow its log and see its changes so far")
    func agentWorkCanBeFollowedLive() async throws {
        let repo = try await makeRepo()
        let pause = Pause()
        let session = try await session(repo, team: AgentTeam(
            name: "Halfway", decomposer: Leaf(), testAuthor: ShellTestAuthor(), implementer: HalfwayImplementer(pause: pause)))
        let key = await ticket(session)
        let work = Task { await session.runUntilFinished() }
        while await !pause.reached { try await Task.sleep(for: .milliseconds(20)) }

        let node = try #require(await session.ledger.workingState().running.first)
        let run = try #require(node.activeRun)
        #expect(node.ticket == key && run.role == .implementer)
        #expect(run.since <= .now)
        let log = session.workspace.artifactsDirectory.appending(path: AgentLog.fileName(node: node.id, run: run.run))
        #expect(try String(contentsOf: log, encoding: .utf8) == "Writing app.txt\n")
        let changes = try await session.workspace.changes(for: node.id)
        #expect(changes.contains("Tests/AppTests/WORK_1Tests/check.sh"))  // committed by the test author
        #expect(changes.contains("+hello"))                                // not committed yet
        #expect(changes.contains("+ draft.txt"))                           // new, not added yet

        await pause.release()
        await work.value
        #expect(await session.ledger.workingState().node(forTicket: key)?.phase == .proven)
        #expect(try String(contentsOf: log, encoding: .utf8) == "Writing app.txt\nDone\n") // kept afterwards
    }

    @Test("When your repo changes while agents run side by side, each names the others it ran with")
    func gitStateChangesNameConcurrentAgents() async throws {
        let repo = try await makeRepo()
        let team = AgentTeam(name: "Tagging", decomposer: Leaf(touchesOwnComponent: true), testAuthor: ShellTestAuthor(filePerTicket: true),
                             implementer: TaggingImplementer(moments: Moments()))
        let session = try await session(repo, team: team)
        let honest = await ticket(session, title: "Honest")
        let sneaky = await ticket(session, title: "Sneaky")

        await session.runUntilFinished()

        let state = await session.ledger.workingState()
        let honestFlag = try #require(state.node(forTicket: honest)?.flags[.escalated])
        let sneakyFlag = try #require(state.node(forTicket: sneaky)?.flags[.escalated])
        #expect(honestFlag.contains("refs/tags/sneaky") && honestFlag.contains("Agents for \(sneaky) ran at the same time"), "\(honestFlag)")
        #expect(sneakyFlag.contains("Agents for \(honest) ran at the same time"), "\(sneakyFlag)")
    }

    @Test("Landing refuses to move the landing branch while a checkout has it checked out")
    func refusesToMoveACheckedOutBranch() async throws {
        let repo = try await makeRepo()
        let storage = FileManager.default.temporaryDirectory.appending(path: "agentos-storage-\(UUID().uuidString)")
        let workspace = try RepositoryWorkspace(root: repo, storage: storage, config: Self.config,
                                                landingBranch: "agentos/main", defaultBranch: "main")
        try await workspace.prepare()
        let directory = try await workspace.createWorktree(for: "wn-1")
        try "hello\n".write(to: directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
        try #require(try await workspace.commitAll(in: directory, message: "work", author: "run-1") != nil)
        try await git(["checkout", "-q", "agentos/main"], in: repo)

        await #expect(throws: AgentFailure.self) { try await workspace.landOnMain("wn-1") }

        try await git(["checkout", "-q", "main"], in: repo)
        let landed = try await workspace.landOnMain("wn-1")
        #expect(try await git(["rev-parse", "agentos/main"], in: repo) == landed)
    }

    @Test("A leaf's worktree can keep its earlier tests while everything else starts again from the landing branch")
    func aWorktreeKeepsTheLeafsEarlierTests() async throws {
        let repo = try await makeRepo()
        let storage = FileManager.default.temporaryDirectory.appending(path: "agentos-storage-\(UUID().uuidString)")
        let workspace = try RepositoryWorkspace(root: repo, storage: storage, config: Self.config,
                                                landingBranch: "agentos/main", defaultBranch: "main")
        try await workspace.prepare()
        let folder = "Tests/AppTests/WORK_1Tests"
        var directory = try await workspace.createWorktree(for: "wn-1")
        try FileManager.default.createDirectory(at: directory.appending(path: folder), withIntermediateDirectories: true)
        try "grep -q hello app.txt\n".write(to: directory.appending(path: "\(folder)/check.sh"), atomically: true, encoding: .utf8)
        try "hello\n".write(to: directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
        try #require(try await workspace.commitAll(in: directory, message: "tests and work", author: "run-1") != nil)

        directory = try await workspace.createWorktree(for: "wn-1", keeping: [folder])

        #expect(try String(contentsOf: directory.appending(path: "\(folder)/check.sh"), encoding: .utf8) == "grep -q hello app.txt\n")
        #expect(try String(contentsOf: directory.appending(path: "app.txt"), encoding: .utf8) == "hi\n")
        #expect(try await git(["rev-parse", "HEAD"], in: directory) == git(["rev-parse", "agentos/main"], in: repo))

        directory = try await workspace.createWorktree(for: "wn-1")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: folder).path))
    }

    @Test("An implementer that fails before submitting leaves its unfinished work to the next attempt")
    func theNextAttemptContinuesUnfinishedWork() async throws {
        let repo = try await makeRepo()
        let implementer = StopsHalfwayOnce()
        let session = try await session(repo, team: AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: ShellTestAuthor(),
                                                              implementer: implementer))
        let key = await ticket(session)

        let reports = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase == .proven, "\(reports.flatMap(\.actions))")
        #expect(await implementer.carriedOver == ["Sources/Greeting.swift", "app.txt"])
        #expect(try await git(["show", "agentos/main:Sources/Greeting.swift"], in: repo) == "let greeting = \"hello\"")
        #expect(try await git(["for-each-ref", "refs/heads/agentos/unfinished/"], in: repo).isEmpty)
    }

    actor StopsHalfwayOnce: AgentOSCore.Implementer {
        private(set) var carriedOver: [String]?
        func implement(_ task: AgentTask) async throws {
            let source = task.directory.appending(path: "Sources/Greeting.swift")
            guard carriedOver == nil, !FileManager.default.fileExists(atPath: source.path) else {
                carriedOver = task.unfinishedWork.sorted()
                try "hello\n".write(to: task.directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
                return
            }
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "let greeting = \"hello\"\n".write(to: source, atomically: true, encoding: .utf8)
            try "hel\n".write(to: task.directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
            try "{}".write(to: task.directory.appending(path: ".agentos-report.json"), atomically: true, encoding: .utf8)
            try "probe\n".write(to: task.scratchDirectory.appending(path: "probe.txt"), atomically: true, encoding: .utf8)
            throw AgentFailure("copilot timed out after 1200.0 seconds")
        }
    }

    @Test("A stopped implementer's unfinished work is kept for the next attempt")
    func aStoppedRunKeepsItsUnfinishedWork() async throws {
        let repo = try await makeRepo()
        let implementer = WritesThenWaits()
        let session = try await session(repo, team: AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: ShellTestAuthor(),
                                                              implementer: implementer))
        let key = await ticket(session)
        var rounds = 0
        while await !implementer.wrote, rounds < 200 {
            _ = await session.step(waitForAgents: false)
            try await Task.sleep(for: .milliseconds(50))
            rounds += 1
        }
        let run = try #require(await session.ledger.workingState().node(forTicket: key)?.activeRun?.run)

        try await session.reconciler.stopRun(run, by: "Morgan")

        let ref = try await git(["for-each-ref", "--format=%(refname)", "refs/heads/agentos/unfinished/"], in: repo)
        #expect(try await git(["show", "\(ref):app.txt"], in: repo) == "hel")
    }

    actor WritesThenWaits: AgentOSCore.Implementer {
        private(set) var wrote = false
        func implement(_ task: AgentTask) async throws {
            try "hel\n".write(to: task.directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
            wrote = true
            try await Task.sleep(for: .seconds(60))
        }
    }

    @Test("A failed run whose work can't be kept goes to a person instead of being retried over it")
    func unfinishedWorkThatCantBeKeptEscalates() async throws {
        let repo = try await makeRepo()
        let session = try await session(repo, team: AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: ShellTestAuthor(),
                                                              implementer: LocksTheIndex()))
        let key = await ticket(session)

        _ = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.flags[.escalated]?.contains("Couldn't keep the failed run's unfinished work") == true)
        #expect(node.failedAttempts == 1)
        let directory = session.workspace.worktree(for: node.id)
        #expect(try String(contentsOf: directory.appending(path: "app.txt"), encoding: .utf8) == "hel\n")
    }

    struct LocksTheIndex: AgentOSCore.Implementer {
        func implement(_ task: AgentTask) async throws {
            try "hel\n".write(to: task.directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
            let gitDirectory = try await ProcessRunner.run("/usr/bin/env", ["git", "rev-parse", "--absolute-git-dir"], in: task.directory)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            FileManager.default.createFile(atPath: gitDirectory + "/index.lock", contents: nil)
            throw AgentFailure("copilot timed out after 1200.0 seconds")
        }
    }

    @Test("Unfinished work survives catch-up, is dropped when it no longer fits, and a new worktree forgets it")
    func unfinishedWorkIsKeptOutsideTheWorktree() async throws {
        let repo = try await makeRepo()
        let storage = FileManager.default.temporaryDirectory.appending(path: "agentos-storage-\(UUID().uuidString)")
        let workspace = try RepositoryWorkspace(root: repo, storage: storage, config: Self.config,
                                                landingBranch: "agentos/main", defaultBranch: "main")
        try await workspace.prepare()
        var directory = try await workspace.createWorktree(for: "wn-1")
        func leaveWork() throws {
            try "hello\n".write(to: directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
            try "new\n".write(to: directory.appending(path: "new.txt"), atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: directory.appending(path: "run-tests.sh"))
        }
        try leaveWork()
        #expect(try await workspace.saveUnfinishedWork(directory, for: "wn-1") == ["app.txt", "new.txt", "run-tests.sh"])
        #expect(try await git(["status", "--porcelain"], in: directory).contains("?? new.txt"))

        // The landing branch moves on, and catching up cleans the worktree.
        try await git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "later"], in: directory)
        try await git(["update-ref", "refs/heads/agentos/main", "HEAD"], in: directory)
        try await git(["reset", "-q", "--hard", "HEAD~1"], in: directory)
        _ = try await workspace.catchUpActiveLeaves(["wn-1"])
        #expect(try await git(["status", "--porcelain"], in: directory).isEmpty)

        #expect(try await workspace.restoreUnfinishedWork(for: "wn-1", in: directory) == ["app.txt", "new.txt", "run-tests.sh"])
        #expect(try String(contentsOf: directory.appending(path: "app.txt"), encoding: .utf8) == "hello\n")
        #expect(try await git(["status", "--porcelain"], in: directory).split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.sorted()
                == ["?? new.txt", "D run-tests.sh", "M app.txt"])

        // It stays saved while the resumed attempt runs, so a crash doesn't lose it; done with, it's forgotten.
        _ = try await workspace.rebaseOntoMain(directory)
        #expect(try await workspace.restoreUnfinishedWork(for: "wn-1", in: directory) == ["app.txt", "new.txt", "run-tests.sh"])
        try await workspace.forgetUnfinishedWork(for: "wn-1")
        _ = try await workspace.rebaseOntoMain(directory)
        #expect(try await workspace.restoreUnfinishedWork(for: "wn-1", in: directory).isEmpty)

        // An attempt that undoes everything it was left leaves nothing to come back.
        try leaveWork()
        _ = try await workspace.saveUnfinishedWork(directory, for: "wn-1")
        _ = try await workspace.rebaseOntoMain(directory)
        #expect(try await workspace.saveUnfinishedWork(directory, for: "wn-1").isEmpty)
        #expect(try await workspace.restoreUnfinishedWork(for: "wn-1", in: directory).isEmpty)
        try leaveWork()

        // Work that conflicts with the branch it comes back to is dropped.
        _ = try await workspace.saveUnfinishedWork(directory, for: "wn-1")
        _ = try await workspace.rebaseOntoMain(directory)
        try "bye\n".write(to: directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
        _ = try await workspace.commitAll(in: directory, message: "other", author: "run-2")
        #expect(try await workspace.restoreUnfinishedWork(for: "wn-1", in: directory).isEmpty)
        #expect(try await git(["status", "--porcelain"], in: directory).isEmpty)

        directory = try await workspace.createWorktree(for: "wn-1")
        try leaveWork()
        _ = try await workspace.saveUnfinishedWork(directory, for: "wn-1")
        directory = try await workspace.createWorktree(for: "wn-1")
        #expect(try await workspace.restoreUnfinishedWork(for: "wn-1", in: directory).isEmpty)
    }

    @Test("A leaf's UI evidence is reviewed with it but never lands; evidence it didn't write isn't its own")
    func uiEvidenceIsReviewedButNeverLands() async throws {
        let repo = try await makeRepo()
        let inherited = #"{"snapshotPaths": [], "windowsOpened": true, "windowsClosed": true}"#
        try inherited.write(to: repo.appending(path: ".agentos-ui-evidence.json"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: repo)
        try await git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "older evidence"], in: repo)
        let storage = FileManager.default.temporaryDirectory.appending(path: "agentos-storage-\(UUID().uuidString)")
        let workspace = try RepositoryWorkspace(root: repo, storage: storage, config: Self.config,
                                                landingBranch: "agentos/main", defaultBranch: "main")
        try await workspace.prepare()
        let directory = try await workspace.createWorktree(for: "wn-1")
        try "hello\n".write(to: directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
        try #require(try await workspace.commitAll(in: directory, message: "work", author: "run-1") != nil)
        #expect(try await workspace.reviewContext(in: directory, against: "agentos/main").uiEvidence == nil)

        try FileManager.default.createDirectory(at: directory.appending(path: ".agentos-ui-evidence"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: directory.appending(path: ".agentos-ui-evidence/after.png"))
        try #"{"snapshotPaths": [".agentos-ui-evidence/after.png"], "windowsOpened": true, "windowsClosed": true}"#
            .write(to: directory.appending(path: ".agentos-ui-evidence.json"), atomically: true, encoding: .utf8)
        let reviewed = try #require(try await workspace.commitAll(in: directory, message: "evidence", author: "run-1"))
        let evidence = try #require(try await workspace.reviewContext(in: directory, against: "agentos/main").uiEvidence)
        #expect(try Data(contentsOf: URL(filePath: try #require(evidence.snapshotPaths.first))) == Data([1, 2, 3]))

        let landed = try await workspace.landOnMain("wn-1")
        #expect(try await git(["rev-parse", "agentos/main"], in: repo) == landed)
        #expect(try await git(["rev-parse", "\(landed)^"], in: repo) == reviewed)
        #expect(try await git(["rev-parse", workspace.branch(for: "wn-1")], in: repo) == reviewed)
        #expect(try await git(["ls-tree", "-r", "--name-only", landed], in: repo).split(separator: "\n").sorted()
                == ["AGENTS.md", "Tests/AppTests/Existing/check.sh", "app.txt", "run-tests.sh"])
        #expect(try await git(["show", "\(landed):app.txt"], in: repo) == "hello")
    }

    @Test func copilotDecomposerAnswersWithChildrenOrQuestions() throws {
        let questions = try #require(CopilotDecomposer.parse(#"{"questions": ["Which buttons?"], "assumptions": [], "children": []}"#))
        #expect(questions.report.questions == ["Which buttons?"])
        #expect(questions.children.isEmpty)

        let object = try #require(CopilotDecomposer.parse(#"Here: {"assumptions": ["8 pt"], "children": [{"title": "A", "acceptanceCriteria": ["a"], "touches": ["App"], "dependsOn": []}]}"#))
        #expect(object.children.map(\.title) == ["A"])
        #expect(object.report.assumptions == ["8 pt"])

        // The older answer: a bare array.
        let array = try #require(CopilotDecomposer.parse(#"[{"title": "B", "acceptanceCriteria": ["b"], "touches": [], "dependsOn": []}]"#))
        #expect(array.children.map(\.title) == ["B"])
        #expect(CopilotDecomposer.parse("{}") == nil)
    }

    @Test("Copilot agents get the policy's denied tools, protected files and a model per role")
    func copilotArguments() {
        var cli = CopilotCLI(executable: "copilot", deniedTools: ["git push", "network installs", "rm", "write(.env)"],
                             protectedPaths: ["AGENTS.md", ".agentos/", "CONTRIBUTING*"])
        cli.model = "model-a"
        let arguments = cli.arguments(prompt: "do it", in: URL(filePath: "/tmp/leaf"))
        #expect(arguments.contains("-s"))
        #expect(!cli.arguments(prompt: "do it", in: URL(filePath: "/tmp/leaf"), silent: false).contains("-s"))
        let denied = zip(arguments, arguments.dropFirst()).filter { $0.0 == "--deny-tool" }.map(\.1)
        #expect(denied.contains("shell(git push)"))
        #expect(denied.contains("shell(npm install)"))
        #expect(denied.contains("shell(rm)"))
        #expect(denied.contains("write(.env)"))
        #expect(denied.contains("write(AGENTS.md)"))
        #expect(!denied.contains { $0.contains(".agentos") || $0.contains("CONTRIBUTING") })
        #expect(arguments.suffix(2) == ["--model", "model-a"])

        let team = AgentTeam.copilot(cli, models: AgentModels(implementer: "model-b"))
        #expect((team.implementer as? CopilotImplementer)?.cli.model == "model-b")
        #expect((team.testAuthor as? CopilotTestAuthor)?.cli.model == "model-a")
    }

    @Test func aCopilotRunThatOverrunsItsTimeLimitIsReportedAsTimedOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agentos-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copilot = directory.appending(path: "copilot")
        try "#!/bin/sh\nsleep 30\n".write(to: copilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)

        let cli = CopilotCLI(executable: copilot.path, timeout: .milliseconds(500))
        let error = await #expect(throws: AgentFailure.self) { try await cli.run("implement", in: directory) }
        #expect(error?.description.hasPrefix("copilot timed out after") == true)
    }

    @Test func theAgentLogEndsWithTheRequestsDeniedForWantOfAnApprover() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agentos-denials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copilot = directory.appending(path: "copilot")
        try """
        #!/bin/sh
        if [ "$2" = quiet ]; then echo done; exit 0; fi
        echo '  └ ✗ Denied, no one to approve shell path (../../../.agentos/scratch/run-1/a.log)'
        echo '  └ ✗ Denied, no one to approve shell path (../../../.agentos/scratch/run-1/a.log)'
        echo '  └ ✗ Denied, no one to approve read path (/tmp/x.swift)'
        echo done
        """.write(to: copilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)
        let log = directory.appending(path: "agent.log")
        try "an earlier run: Denied, no one to approve shell path (/old)\n".write(to: log, atomically: true, encoding: .utf8)

        let cli = CopilotCLI(executable: copilot.path, timeout: .seconds(10))
        _ = try await cli.run("implement", in: directory, log: log, silent: false)
        let last = try #require(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").last)
        #expect(last.contains("Harness: 3 requests were denied"))
        #expect(last.contains("shell path (../../../.agentos/scratch/run-1/a.log); read path (/tmp/x.swift)."))
        #expect(!last.contains("/old"))

        _ = try await cli.run("quiet", in: directory, log: log, silent: false)
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").last?.hasSuffix("done") == true)
    }

    // MARK: Helpers

    @Test("A test author that runs out of time leaves its draft to the next run, which starts from the harness's run of it")
    func theNextTestAuthorContinuesTheDraft() async throws {
        let repo = try await makeRepo()
        let author = TimesOutOnce()
        let session = try await session(repo, team: AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: author,
                                                              implementer: Implementer()))
        let key = await ticket(session)

        let reports = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase == .proven, "\(reports.flatMap(\.actions))")
        #expect(await author.carriedOver == ["Tests/AppTests/\(node.spec.testTarget)/check.sh", "app.txt"])
        let check = try #require(await author.draftCheck)
        #expect(check.contains("\(node.spec.testTarget) failed") && check.contains("Full log:"), "\(check)")
        let kinds = await session.ledger.records(for: node.id).map(\.event.kind)
        #expect(kinds.contains { if case .attemptsReset = $0 { return true }; return false })
        #expect(try await git(["for-each-ref", "refs/heads/agentos/drafts/"], in: repo).isEmpty)
    }

    actor TimesOutOnce: TestAuthor {
        private(set) var carriedOver: [String]?
        private(set) var draftCheck: String?
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            let test = task.directory.appending(path: "\(task.testFolder)/check.sh")
            guard FileManager.default.fileExists(atPath: test.path) else {
                try FileManager.default.createDirectory(at: test.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "grep -q hello app.txt\n".write(to: test, atomically: true, encoding: .utf8)
                try "placeholder\n".write(to: task.directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
                throw AgentFailure("copilot timed out after 1200.0 seconds: still building")
            }
            carriedOver = task.unfinishedWork.sorted()
            draftCheck = task.draftCheck
            return AgentReport()
        }
    }

    @Test("A test author that leaves the same draft twice goes to a person")
    func anUnchangedDraftEscalates() async throws {
        let repo = try await makeRepo()
        let session = try await session(repo, team: AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: AlwaysTimesOut(),
                                                              implementer: Implementer()))
        let key = await ticket(session)

        _ = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.flags[.escalated]?.contains("No progress") == true, "\(node.flags)")
        #expect(node.failedAttempts == 2)
        #expect(node.testDraft == ["Tests/AppTests/\(node.spec.testTarget)/check.sh"])
    }

    struct AlwaysTimesOut: TestAuthor {
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            let test = task.directory.appending(path: "\(task.testFolder)/check.sh")
            try FileManager.default.createDirectory(at: test.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "grep -q hello app.txt\n".write(to: test, atomically: true, encoding: .utf8)
            throw AgentFailure("copilot timed out after 1200.0 seconds: \(UUID().uuidString)")
        }
    }

    @Test("Tests a failed run left uncommitted without a kept draft are continued after harness:retry")
    func leftoverTestsAreAdoptedAsADraft() async throws {
        let repo = try await makeRepo()
        let author = LocksTheIndexOnce()
        let session = try await session(repo, team: AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: author,
                                                              implementer: Implementer()))
        let key = await ticket(session)
        _ = await session.runUntilFinished()
        let stopped = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(stopped.flags[.escalated]?.contains("Couldn't keep the failed test author's draft") == true, "\(stopped.flags)")
        #expect(stopped.testDraft == nil)

        let gitDirectory = try await git(["rev-parse", "--absolute-git-dir"], in: session.workspace.worktree(for: stopped.id))
        try FileManager.default.removeItem(atPath: gitDirectory + "/index.lock")
        await session.tracker.addLabel("harness:retry", to: key, by: .human("Alice"))
        let reports = await session.runUntilFinished()

        #expect(await session.ledger.workingState().node(forTicket: key)?.phase == .proven, "\(reports.flatMap(\.actions))")
        #expect(await author.carriedOver == ["Tests/AppTests/\(stopped.spec.testTarget)/check.sh"])
    }

    actor LocksTheIndexOnce: TestAuthor {
        private var locked = false
        private(set) var carriedOver: [String]?
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            guard !locked else {
                carriedOver = task.unfinishedWork.sorted()
                return AgentReport()
            }
            locked = true
            let test = task.directory.appending(path: "\(task.testFolder)/check.sh")
            try FileManager.default.createDirectory(at: test.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "grep -q hello app.txt\n".write(to: test, atomically: true, encoding: .utf8)
            let gitDirectory = try await ProcessRunner.run("/usr/bin/env", ["git", "rev-parse", "--absolute-git-dir"], in: task.directory)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            FileManager.default.createFile(atPath: gitDirectory + "/index.lock", contents: nil)
            throw AgentFailure("copilot timed out after 1200.0 seconds")
        }
    }

    @Test("A test draft outlives new worktrees; when the landing branch changed under it, only its tests come back")
    func aTestDraftKeepsItsTestsWhenItNoLongerFits() async throws {
        let repo = try await makeRepo()
        let storage = FileManager.default.temporaryDirectory.appending(path: "agentos-storage-\(UUID().uuidString)")
        let workspace = try RepositoryWorkspace(root: repo, storage: storage, config: Self.config,
                                                landingBranch: "agentos/main", defaultBranch: "main")
        try await workspace.prepare()
        var directory = try await workspace.createWorktree(for: "wn-1")
        let test = "Tests/AppTests/WORK_1Tests/check.sh"
        try FileManager.default.createDirectory(at: directory.appending(path: "Tests/AppTests/WORK_1Tests"), withIntermediateDirectories: true)
        try "grep -q hello app.txt\n".write(to: directory.appending(path: test), atomically: true, encoding: .utf8)
        try "placeholder\n".write(to: directory.appending(path: "app.txt"), atomically: true, encoding: .utf8)
        #expect(try await workspace.saveTestDraft(directory, for: "wn-1") == [test, "app.txt"].sorted())

        directory = try await workspace.createWorktree(for: "wn-1")
        try await workspace.removeWorktree(for: "wn-1")
        directory = try await workspace.createWorktree(for: "wn-1")
        #expect(try await workspace.restoreTestDraft(for: "wn-1", in: directory) == [test, "app.txt"].sorted())
        #expect(try String(contentsOf: directory.appending(path: "app.txt"), encoding: .utf8) == "placeholder\n")

        // Other work lands on the placeholder's file.
        try await git(["checkout", "-q", "agentos/main"], in: repo)
        try "landed\n".write(to: repo.appending(path: "app.txt"), atomically: true, encoding: .utf8)
        try await git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qam", "landed"], in: repo)
        try await git(["checkout", "-q", "main"], in: repo)
        directory = try await workspace.createWorktree(for: "wn-1")

        #expect(try await workspace.restoreTestDraft(for: "wn-1", in: directory) == [test])
        #expect(try String(contentsOf: directory.appending(path: "app.txt"), encoding: .utf8) == "landed\n")
        #expect(try String(contentsOf: directory.appending(path: test), encoding: .utf8) == "grep -q hello app.txt\n")
        try await workspace.forgetTestDraft(for: "wn-1")
        #expect(try await workspace.restoreTestDraft(for: "wn-1", in: directory).isEmpty)
    }

    @Test("When the change review sends the tests back, the implementer continues from its kept implementation")
    func theImplementationIsKeptWhileTheTestsAreFixed() async throws {
        let repo = try await makeRepo()
        let implementer = RecordsUnfinishedWork()
        var team = AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: ShellTestAuthor(), implementer: implementer)
        team.reviewer = FindsTestFaultOnce()
        let session = try await session(repo, team: team)
        let key = await ticket(session)

        let reports = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase == .proven, "\(node.flags) \(reports.flatMap(\.actions))")
        #expect(await implementer.unfinishedWork == [[], ["app.txt"]])
        #expect(try await git(["for-each-ref", "refs/heads/agentos/kept-implementation/"], in: repo).isEmpty)
    }

    actor RecordsUnfinishedWork: AgentOSCore.Implementer {
        private(set) var unfinishedWork: [[String]] = []
        func implement(_ task: AgentTask) async throws {
            unfinishedWork.append(task.unfinishedWork.sorted())
            try await Implementer().implement(task)
        }
    }

    actor FindsTestFaultOnce: Reviewer {
        private var found = false
        func review(_ request: ReviewRequest) async throws -> ReviewResult {
            guard request.stage == .change, !found else { return ReviewResult(passed: true, findings: []) }
            found = true
            return ReviewResult(passed: false, findings: [], testFindings: ["The test doesn't name the greeting."])
        }
    }

    @Test("A ticket going round stops at its run budget; a person acting on it starts a new one")
    func theRunBudgetStopsATicketGoingRound() async throws {
        let repo = try await makeRepo()
        let implementer = RecordsUnfinishedWork()
        var team = AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: ShellTestAuthor(), implementer: implementer)
        team.reviewer = AlwaysFindsTestFault()
        var harness = HarnessSettings()
        harness.maxAgentRuns = 3
        let session = try await session(repo, team: team, harness: harness)
        let key = await ticket(session)

        _ = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.flags[.escalated]?.contains("Agents ran 3 times") == true, "\(node.flags)")
        #expect(await implementer.unfinishedWork.count == 1)
        await session.tracker.addLabel("harness:retry", to: key, by: .human("Alice"))
        _ = await session.runUntilFinished()
        #expect(await implementer.unfinishedWork.count == 3)
    }

    struct AlwaysFindsTestFault: Reviewer {
        func review(_ request: ReviewRequest) async throws -> ReviewResult {
            guard request.stage == .change else { return ReviewResult(passed: true, findings: []) }
            return ReviewResult(passed: false, findings: [], testFindings: ["The test doesn't name the greeting."])
        }
    }

    @Test("An escalation gets one diagnosis on its ticket, read-only; the ticket stays with the person")
    func anEscalationIsDiagnosedOnce() async throws {
        let repo = try await makeRepo()
        let diagnoser = RecordingDiagnoser()
        var team = AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: AlwaysTimesOut(), implementer: Implementer())
        team.diagnoser = diagnoser
        let session = try await session(repo, team: team)
        let key = await ticket(session)

        _ = await session.runUntilFinished()
        _ = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.flags[.escalated]?.contains("No progress") == true, "\(node.flags)")
        #expect(!node.needsDiagnosis)
        let requests = await diagnoser.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.escalation == node.flags[.escalated])
        #expect(request.history.contains { $0.contains("test draft of") })
        #expect(request.directory == session.workspace.worktree(for: node.id))
        let comments = await session.tracker.ticket(key)?.comments.map(\.text) ?? []
        #expect(comments.contains { $0.contains("🩺") && $0.contains("Split it in two.") }, "\(comments)")
    }

    @Test("A diagnoser that fails is recorded and not retried; the escalation keeps its reason")
    func aFailedDiagnosisIsNotRetried() async throws {
        let repo = try await makeRepo()
        let diagnoser = RecordingDiagnoser(fails: true)
        var team = AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: AlwaysTimesOut(), implementer: Implementer())
        team.diagnoser = diagnoser
        let session = try await session(repo, team: team)
        let key = await ticket(session)

        _ = await session.runUntilFinished()
        _ = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.flags[.escalated]?.contains("No progress") == true, "\(node.flags)")
        #expect(await diagnoser.requests.count == 1)
        let kinds = await session.ledger.records(for: node.id).map(\.event.kind)
        #expect(kinds.contains { if case .diagnosisRecorded(_, let diagnosis) = $0 { diagnosis.cause.contains("couldn't finish") } else { false } })
    }

    actor RecordingDiagnoser: Diagnoser {
        let fails: Bool
        private(set) var requests: [DiagnosisRequest] = []
        init(fails: Bool = false) { self.fails = fails }
        func diagnose(_ request: DiagnosisRequest) async throws -> Diagnosis {
            requests.append(request)
            if fails { throw AgentFailure("copilot timed out after 600.0 seconds") }
            return Diagnosis(cause: "The ticket is too big for one run.", nextStep: "Split it in two.")
        }
    }

    @Test("A repo may give its agents longer, up to the harness's limit; the team runs with it")
    func agentTimeoutsComeFromTheRepoConfig() throws {
        var config = Self.config
        config.agents = RepoConfig.Agents(timeouts: ["testAuthor": 1800, "reviewer": 7200, "planner": 600])
        let policy = EffectivePolicy.resolve(harness: HarnessSettings(), repo: config, defaultBranch: "main")
        #expect(policy.agentTimeouts["testAuthor"] == 1800)
        #expect(policy.agentTimeouts["reviewer"] == 1200)
        #expect(policy.problems.map(\.title).sorted() == ["Repo config sets a timeout for an unknown agent: planner",
                                                           "Repo config sets the reviewer timeout to 7200 seconds"])
        let team = RepositorySession.copilotTeam(executable: "/not-executed/copilot", policy: policy)
        #expect((team.testAuthor as? CopilotTestAuthor)?.cli.timeout == .seconds(1800))
        #expect((team.implementer as? CopilotImplementer)?.cli.timeout == .seconds(1200))
        #expect((team.reviewer as? CopilotReviewer)?.cli.timeout == .seconds(1200))
        #expect((team.diagnoser as? CopilotDiagnoser)?.cli.timeout == .seconds(600))
    }

    @Test("The harness sets each agent's timeout and how long a repo may choose; a repo's own still wins within that")
    func agentTimeoutsComeFromTheHarnessSettings() throws {
        var harness = HarnessSettings()
        harness.agentTimeouts["decomposer"] = 1800
        harness.agentTimeouts["implementer"] = 9000
        harness.maxAgentTimeout = 7200
        var config = Self.config
        config.agents = RepoConfig.Agents(timeouts: ["reviewer": 7200, "testAuthor": 7260])
        let policy = EffectivePolicy.resolve(harness: harness, repo: config, defaultBranch: "main")
        #expect(policy.agentTimeouts == ["decomposer": 1800, "testAuthor": 1200, "implementer": 7200,
                                         "reviewer": 7200, "diagnoser": 600])
        #expect(policy.problems.map(\.title) == ["Repo config sets the testAuthor timeout to 7260 seconds"])
        let team = RepositorySession.copilotTeam(executable: "/not-executed/copilot", policy: policy)
        #expect((team.decomposer as? CopilotDecomposer)?.cli.timeout == .seconds(1800))

        let saved = try JSONEncoder().encode(harness)
        #expect(try JSONDecoder().decode(HarnessSettings.self, from: saved) == harness)
        var old = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        old["agentTimeouts"] = ["decomposer": 1800]
        old["maxAgentTimeout"] = nil
        let loaded = try JSONDecoder().decode(HarnessSettings.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(loaded.agentTimeouts == ["decomposer": 1800, "testAuthor": 1200, "implementer": 1200,
                                         "reviewer": 1200, "diagnoser": 600])
        #expect(loaded.maxAgentTimeout == 3600)
    }

    @Test("A proposed child with more criteria than one run proves gets a finding that asks to split it")
    func oversizedChildrenAreFound() {
        let criteria = (1...7).map { "Criterion \($0) holds." }
        #expect(BreakdownChecker.check([ChildProposal(title: "Everything", acceptanceCriteria: criteria)])
                == [.tooManyCriteria(childPosition: 1, childTitle: "Everything", count: 7, limit: 6)])
        #expect(BreakdownChecker.check([ChildProposal(title: "Enough", acceptanceCriteria: Array(criteria.prefix(6)))]).isEmpty)
    }

    @Test("A stopped test author's draft is kept and recorded, and continued after harness:retry")
    func aStoppedTestAuthorKeepsItsDraft() async throws {
        let repo = try await makeRepo()
        let author = WritesTestsThenWaits()
        let session = try await session(repo, team: AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: author,
                                                              implementer: Implementer()))
        let key = await ticket(session)
        var rounds = 0
        while await !author.wrote, rounds < 200 {
            _ = await session.step(waitForAgents: false)
            try await Task.sleep(for: .milliseconds(50))
            rounds += 1
        }
        let run = try #require(await session.ledger.workingState().node(forTicket: key)?.activeRun?.run)

        try await session.reconciler.stopRun(run, by: "Morgan")

        let stopped = try #require(await session.ledger.workingState().node(forTicket: key))
        let test = "Tests/AppTests/\(stopped.spec.testTarget)/check.sh"
        #expect(stopped.testDraft == [test])
        await session.tracker.addLabel("harness:retry", to: key, by: .human("Alice"))
        _ = await session.runUntilFinished()
        #expect(await session.ledger.workingState().node(forTicket: key)?.phase == .proven)
        #expect(await author.carriedOver == [test])
    }

    actor WritesTestsThenWaits: TestAuthor {
        private(set) var wrote = false
        private(set) var carriedOver: [String]?
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            guard !wrote else {
                carriedOver = task.unfinishedWork.sorted()
                return AgentReport()
            }
            let test = task.directory.appending(path: "\(task.testFolder)/check.sh")
            try FileManager.default.createDirectory(at: test.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "grep -q hello app.txt\n".write(to: test, atomically: true, encoding: .utf8)
            wrote = true
            try await Task.sleep(for: .seconds(60))
            return AgentReport()
        }
    }

    @Test("Tests left by an earlier run that still can't be kept go to a person; the worktree holding them stays")
    func leftoverTestsThatCantBeKeptEscalate() async throws {
        let repo = try await makeRepo()
        let author = LocksTheIndexOnce()
        let session = try await session(repo, team: AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: author,
                                                              implementer: Implementer()))
        let key = await ticket(session)
        _ = await session.runUntilFinished()
        // Held open, so the harness doesn't take the lock for one a killed git left behind.
        let stopped = try #require(await session.ledger.workingState().node(forTicket: key))
        let gitDirectory = try await git(["rev-parse", "--absolute-git-dir"], in: session.workspace.worktree(for: stopped.id))
        let lock = try #require(FileHandle(forReadingAtPath: gitDirectory + "/index.lock"))
        defer { try? lock.close() }

        await session.tracker.addLabel("harness:retry", to: key, by: .human("Alice"))
        _ = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.flags[.escalated]?.contains("Couldn't keep the tests an earlier run left") == true, "\(node.flags)")
        #expect(await author.carriedOver == nil)
        let test = session.workspace.worktree(for: node.id).appending(path: "Tests/AppTests/\(node.spec.testTarget)/check.sh")
        #expect(try String(contentsOf: test, encoding: .utf8) == "grep -q hello app.txt\n")
    }

    @Test("When the implementation can't be kept, the tests aren't sent back over it: the branch stays for a person")
    func anImplementationThatCantBeKeptIsntReset() async throws {
        let repo = try await makeRepo()
        let implementer = RecordsUnfinishedWork()
        var team = AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: ShellTestAuthor(), implementer: implementer)
        team.reviewer = BlocksKeptImplementations()
        let session = try await session(repo, team: team)
        let key = await ticket(session)

        _ = await session.runUntilFinished()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.flags[.escalated]?.contains("couldn't be kept before sending them back") == true, "\(node.flags)")
        let directory = session.workspace.worktree(for: node.id)
        #expect(try String(contentsOf: directory.appending(path: "app.txt"), encoding: .utf8) == "hello\n")
        #expect(try await git(["rev-list", "--count", "agentos/main..HEAD"], in: directory) == "2")
        #expect(await implementer.unfinishedWork.count == 1)
    }

    /// Finds a problem in the tests, after locking the ref the implementation would be kept in.
    struct BlocksKeptImplementations: Reviewer {
        func review(_ request: ReviewRequest) async throws -> ReviewResult {
            guard request.stage == .change else { return ReviewResult(passed: true, findings: []) }
            let common = try await ProcessRunner.run("/usr/bin/env", ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                                     in: request.directory).output.trimmingCharacters(in: .whitespacesAndNewlines)
            let refs = URL(filePath: common).appending(path: "refs/heads/agentos/kept-implementation")
            try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: refs.appending(path: request.spec.id + ".lock").path, contents: nil)
            return ReviewResult(passed: false, findings: [], testFindings: ["The test doesn't name the greeting."])
        }
    }

    @Test("A diagnoser a person stops isn't started again")
    func aStoppedDiagnosisIsNotRestarted() async throws {
        let repo = try await makeRepo()
        let diagnoser = WaitingDiagnoser()
        var team = AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: AlwaysTimesOut(), implementer: Implementer())
        team.diagnoser = diagnoser
        let session = try await session(repo, team: team)
        let key = await ticket(session)
        var rounds = 0
        while await diagnoser.started == 0, rounds < 400 {
            _ = await session.step(waitForAgents: false)
            try await Task.sleep(for: .milliseconds(50))
            rounds += 1
        }
        let run = try #require(await session.ledger.workingState().node(forTicket: key)?.activeRun?.run)

        try await session.reconciler.stopRun(run, by: "Morgan")
        _ = await session.runUntilFinished()

        #expect(await diagnoser.started == 1)
        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(!node.needsDiagnosis)
        #expect(node.flags[.escalated]?.contains("No progress") == true, "\(node.flags)")
        let kinds = await session.ledger.records(for: node.id).map(\.event.kind)
        #expect(kinds.contains { if case .diagnosisRecorded(_, let diagnosis) = $0 { diagnosis.cause.contains("stopped by Morgan") } else { false } })
    }

    @Test("A person's harness:retry stops a running diagnosis instead of being turned away")
    func aRetryStopsARunningDiagnosis() async throws {
        let repo = try await makeRepo()
        let diagnoser = WaitingDiagnoser()
        var team = AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: AlwaysTimesOut(), implementer: Implementer())
        team.diagnoser = diagnoser
        let session = try await session(repo, team: team)
        let key = await ticket(session)
        var rounds = 0
        while await diagnoser.started == 0, rounds < 400 {
            _ = await session.step(waitForAgents: false)
            try await Task.sleep(for: .milliseconds(50))
            rounds += 1
        }
        let id = try #require(await session.ledger.workingState().node(forTicket: key)?.id)

        await session.tracker.addLabel("harness:retry", to: key, by: .human("Alice"))
        _ = await session.runUntilFinished()

        let kinds = await session.ledger.records(for: id).map(\.event.kind)
        #expect(kinds.contains { if case .signalAccepted(_, .retry, _) = $0 { true } else { false } })
        #expect(!kinds.contains { if case .signalRejected = $0 { true } else { false } })
        #expect(kinds.contains { if case .diagnosisRecorded(_, let diagnosis) = $0 { diagnosis.cause.contains("stopped by Alice") } else { false } })
        // The retry ran the test author again; its new escalation gets a diagnosis of its own.
        #expect(await diagnoser.started == 2)
    }

    /// Waits on its first diagnosis, so a test can stop it; answers later ones at once.
    actor WaitingDiagnoser: Diagnoser {
        private(set) var started = 0
        func diagnose(_ request: DiagnosisRequest) async throws -> Diagnosis {
            started += 1
            if started == 1 { try await Task.sleep(for: .seconds(60)) }
            return Diagnosis(cause: "late", nextStep: "late")
        }
    }

    @Test("The diagnoser can't write or run commands, and sees copies of only the logs it was given")
    func theDiagnoserIsReadOnlyAndSeesOnlyItsLogs() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "agentos-diagnoser-\(UUID().uuidString)")
        let logs = folder.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.log", "b.log", "unrelated.log"] {
            try "log \(name)\n".write(to: logs.appending(path: name), atomically: true, encoding: .utf8)
        }
        let copilot = folder.appending(path: "copilot")
        try """
            #!/bin/sh
            here="$(dirname "$0")"; prev=""
            for a in "$@"; do
              [ "$prev" = "--add-dir" ] && { ls "$a" > "$here/seen.txt"; echo "$a" > "$here/copies.txt"; }
              prev="$a"
            done
            printf '%s\n' "$@" > "$here/args.txt"
            printf '%s\n' '{"cause":"Too big.","nextStep":"Split it."}'
            """.write(to: copilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)
        let policy = EffectivePolicy.resolve(harness: HarnessSettings(), repo: Self.config, defaultBranch: "main")
        let team = RepositorySession.copilotTeam(executable: copilot.path, policy: policy)
        let diagnoser = try #require(team.diagnoser)

        let diagnosis = try await diagnoser.diagnose(DiagnosisRequest(
            ticketKey: "GH-1", title: "Greeting", acceptanceCriteria: ["Says hello"], escalation: "No progress",
            history: [], logs: [logs.appending(path: "a.log"), logs.appending(path: "b.log")], directory: folder, log: nil))

        #expect(diagnosis == Diagnosis(cause: "Too big.", nextStep: "Split it."))
        let seen = try String(contentsOf: folder.appending(path: "seen.txt"), encoding: .utf8)
        #expect(seen == "1-a.log\n2-b.log\n")
        let copies = try String(contentsOf: folder.appending(path: "copies.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: copies))
        let args = try String(contentsOf: folder.appending(path: "args.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        let denied = zip(args, args.dropFirst()).filter { $0.0 == "--deny-tool" }.map(\.1)
        #expect(denied.contains("write") && denied.contains("shell"), "\(denied)")
    }

    @Test("A diagnosis posted on the ticket is cut to a readable length")
    func aLongDiagnosisIsCut() throws {
        let long = String(repeating: "x", count: 5000)
        let diagnosis = try CopilotDiagnoser.diagnosis(from: #"{"cause":"\#(long)","nextStep":"Split it."}"#)
        #expect(diagnosis.cause.count == 800)
        #expect(diagnosis.nextStep == "Split it.")
    }

    private func makeRepo() async throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appending(path: "agentos-repo-\(UUID().uuidString)")
        let files = ["app.txt": "hi\n", "run-tests.sh": Self.runner, "AGENTS.md": "# Rules\n", "Tests/AppTests/Existing/check.sh": "true\n"]
        for (path, text) in files {
            let url = repo.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try await git(["init", "-q", "-b", "main"], in: repo)
        try await git(["add", "."], in: repo)
        try await git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"], in: repo)
        return repo
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
