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
        func proposeChildren(of parent: NodeSpec, existingComponents: [String]) async throws -> [ChildProposal] {
            [ChildProposal(title: parent.title, acceptanceCriteria: parent.acceptanceCriteria, touches: ["App"])]
        }
    }

    struct ShellTestAuthor: TestAuthor {
        var alsoEdits: String?
        func writeAcceptanceTests(_ task: AgentTask) async throws {
            let url = task.directory.appending(path: "\(task.testFolder)/check.sh")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "grep -q hello app.txt\n".write(to: url, atomically: true, encoding: .utf8)
            if let alsoEdits {
                try "changed by the test author\n".write(to: task.directory.appending(path: alsoEdits), atomically: true, encoding: .utf8)
            }
        }
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

    func team(alsoEdits: String? = nil, renames: String? = nil, runsGit: [String]? = nil, authorAlsoEdits: String? = nil) -> AgentTeam {
        AgentTeam(name: "Fake", decomposer: Leaf(), testAuthor: ShellTestAuthor(alsoEdits: authorAlsoEdits),
                  implementer: Implementer(alsoEdits: alsoEdits, renames: renames, runsGit: runsGit))
    }

    func session(_ repo: URL, team: AgentTeam) async throws -> RepositorySession {
        let storage = FileManager.default.temporaryDirectory.appending(path: "agentos-storage-\(UUID().uuidString)")
        let ledger = try Ledger(store: FileLedgerStore(fileURL: storage.appending(path: "ledger.jsonl")))
        let policy = EffectivePolicy.resolve(harness: HarnessSettings(), repo: Self.config, defaultBranch: "main")
        let location = RepositoryLocation(root: repo, identity: "test", branch: "main", commit: try await git(["rev-parse", "main"], in: repo))
        return try RepositorySession(location: location, storage: storage, ledger: ledger, config: Self.config, policy: policy, team: team)
    }

    func ticket(_ session: RepositorySession) async -> String {
        let key = await session.tracker.createTicket(
            title: "Greeting", description: "Say hello", acceptanceCriteria: ["app.txt says hello"], by: .human("Alice")).key
        await session.tracker.addLabel("harness:go", to: key, by: .human("Alice"))
        return key
    }

    @Test("A leaf lands on agentos/main; your checkout and main stay as they were")
    func landsOnTheLandingBranchOnly() async throws {
        let repo = try await makeRepo()
        let main = try await git(["rev-parse", "main"], in: repo)
        let session = try await session(repo, team: team())
        let key = await ticket(session)

        let reports = await session.runUntilIdle()

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

    @Test("Changing a protected file fails the check, so nothing lands")
    func protectedPathsAreEnforced() async throws {
        let repo = try await makeRepo()
        let session = try await session(repo, team: team(alsoEdits: "AGENTS.md"))
        let key = await ticket(session)

        await session.runUntilIdle()

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

        await session.runUntilIdle()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase != .proven)
        #expect(node.recentFailures.first == "Changed protected files (not allowed): AGENTS.md", "\(node.recentFailures)")
        #expect(try await git(["rev-parse", "agentos/main"], in: repo) == git(["rev-parse", "main"], in: repo))
    }

    @Test("The test author may only add files in its own test folder")
    func testAuthorStaysInItsFolder() async throws {
        let repo = try await makeRepo()
        let session = try await session(repo, team: team(authorAlsoEdits: "app.txt"))
        let key = await ticket(session)

        await session.runUntilIdle()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase != .proven)
        #expect(node.flags[.escalated]?.contains("wrote outside its own test folder") == true, "\(node.flags)")
        #expect(try await git(["rev-parse", "agentos/main"], in: repo) == git(["rev-parse", "main"], in: repo))
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

        await session.runUntilIdle()

        let node = try #require(await session.ledger.workingState().node(forTicket: key))
        #expect(node.phase != .proven)
        #expect(node.failedAttempts == 1, "escalated straight away")
        #expect(node.flags[.escalated]?.contains("changed your repo outside agentos/: \(named)") == true, "\(node.flags)")
        #expect(try await git(["rev-parse", "agentos/main"], in: repo) == git(["rev-parse", "main"], in: repo))
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

    @Test("Copilot agents get the policy's denied tools, protected files and a model per role")
    func copilotArguments() {
        var cli = CopilotCLI(executable: "copilot", deniedTools: ["git push", "network installs", "rm", "write(.env)"],
                             protectedPaths: ["AGENTS.md", ".agentos/", "CONTRIBUTING*"])
        cli.model = "model-a"
        let arguments = cli.arguments(prompt: "do it", in: URL(filePath: "/tmp/leaf"))
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

    // MARK: Helpers

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
