// API contract: AgentTask supplies a writable, submission-excluded scratchDirectory for each implementer run,
// and CopilotImplementer.prompt(for:) exposes the instructions sent to that run.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_29_3Tests {
    @Test
    func everyImplementerRunReceivesWritableScratchInsideItsWorkingCopy() async throws {
        let result = try await runImplementer()

        #expect(result.scratchExistedWhenRunStarted)
        #expect(result.scratchWasInsideWorkingCopy)
        #expect(result.experimentWasWritable)
    }

    @Test
    func implementerPromptDirectsExperimentsToTheSuppliedScratchFolderInsteadOfTmp() {
        let task = taskForPrompt()

        let prompt = CopilotImplementer.prompt(for: task)

        #expect(prompt.contains(task.scratchDirectory.path))
        #expect(prompt.localizedCaseInsensitiveContains("experiment"))
        #expect(prompt.contains("/tmp"))
        #expect(prompt.localizedCaseInsensitiveContains("instead"))
    }

    @Test
    func implementerPromptProtectsTicketScopeAndBrokenAcceptanceTests() {
        let prompt = CopilotImplementer.prompt(for: taskForPrompt())

        #expect(prompt.localizedCaseInsensitiveContains("outside the ticket's requested scope"))
        #expect(prompt.localizedCaseInsensitiveContains("report a broken acceptance test"))
        #expect(prompt.localizedCaseInsensitiveContains("instead of changing"))
        #expect(prompt.localizedCaseInsensitiveContains("working around"))
    }

    @Test
    func scratchExperimentsAreNotIncludedInTheSubmittedImplementation() async throws {
        let result = try await runImplementer()

        #expect(result.experimentWasWritable)
        #expect(result.submittedFiles.contains("app.txt"))
        #expect(!result.submittedFiles.contains { $0.contains("experiment.txt") })
        #expect(!result.submittedFiles.contains { $0.hasPrefix(result.scratchRelativePath + "/") })
    }

    private func taskForPrompt() -> AgentTask {
        let directory = URL(filePath: "/worktrees/wn-GH-29.3", directoryHint: .isDirectory)
        return AgentTask(
            spec: NodeSpec(
                id: "wn-GH-29.3",
                parent: nil,
                kind: .leaf,
                title: "Safe experiments",
                intent: "Keep experiments out of submissions",
                acceptanceCriteria: ["An implementer can experiment safely"],
                touches: ["AgentOSAdapters"]
            ),
            run: "run-1",
            directory: directory,
            testFolder: "Tests/AppTests/GH_29_3Tests",
            scratchDirectory: directory.appending(path: ".agentos/scratch/run-1", directoryHint: .isDirectory)
        )
    }

    private func runImplementer() async throws -> RunResult {
        let repo = try await makeRepo()
        let storage = FileManager.default.temporaryDirectory
            .appending(path: "agentos-gh-29-3-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
        let ledger = try Ledger(store: FileLedgerStore(fileURL: storage.appending(path: "ledger.jsonl")))
        let config = RepoConfig(
            test: .init(command: "sh run-tests.sh", only: "{suite}"),
            leafTests: .init(target: "AppTests", folder: "Tests/AppTests/")
        )
        let policy = EffectivePolicy.resolve(harness: HarnessSettings(), repo: config, defaultBranch: "main")
        let location = RepositoryLocation(
            root: repo,
            identity: "gh-29-3",
            branch: "main",
            commit: try await git(["rev-parse", "main"], in: repo)
        )
        let observation = RunObservation()
        let team = AgentTeam(
            name: "Scratch observer",
            decomposer: SingleLeaf(),
            testAuthor: ShellTestAuthor(),
            implementer: ExperimentingImplementer(observation: observation)
        )
        let session = try RepositorySession(
            location: location,
            storage: storage,
            ledger: ledger,
            config: config,
            policy: policy,
            team: team
        )
        let ticket = await session.tracker.newTicket(
            title: "Safe experiments",
            description: "Give the implementer safe experiment space",
            acceptanceCriteria: ["app.txt says implemented"],
            blockedBy: [],
            by: .human("Alice")
        )!.key
        await session.tracker.addLabel("harness:go", to: ticket, by: .human("Alice"))

        _ = await session.runUntilIdle()

        let node = try #require(await session.ledger.workingState().node(forTicket: ticket))
        #expect(node.phase == .proven)
        let submittedFiles = try await git(["ls-tree", "-r", "--name-only", "agentos/main"], in: repo)
            .split(separator: "\n")
            .map(String.init)
        return await observation.result(submittedFiles: submittedFiles)
    }

    private func makeRepo() async throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appending(path: "agentos-gh-29-3-repo-\(UUID().uuidString)", directoryHint: .isDirectory)
        let files = [
            "app.txt": "not implemented\n",
            "run-tests.sh": #"grep -q implemented app.txt"# + "\n",
            "Tests/AppTests/Existing/check.sh": "true\n",
        ]
        for (path, contents) in files {
            let file = repo.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        try await git(["init", "-q", "-b", "main"], in: repo)
        try await git(["add", "."], in: repo)
        try await git(
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "initial"],
            in: repo
        )
        return repo
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct SingleLeaf: Decomposer {
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

private struct ShellTestAuthor: TestAuthor {
    func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
        let test = task.directory.appending(path: "\(task.testFolder)/check.sh")
        try FileManager.default.createDirectory(at: test.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "grep -q implemented app.txt\n".write(to: test, atomically: true, encoding: .utf8)
        return AgentReport()
    }
}

private struct ExperimentingImplementer: Implementer {
    let observation: RunObservation

    func implement(_ task: AgentTask) async throws {
        let scratchExisted = FileManager.default.fileExists(atPath: task.scratchDirectory.path)
        let relative = task.scratchDirectory.path
            .replacingOccurrences(of: task.directory.path + "/", with: "")
        let inside = relative != task.scratchDirectory.path && !relative.hasPrefix("../")
        let experiment = task.scratchDirectory.appending(path: "experiment.txt")
        var writable = false
        do {
            try "prototype\n".write(to: experiment, atomically: true, encoding: .utf8)
            writable = try String(contentsOf: experiment, encoding: .utf8) == "prototype\n"
        } catch {
            writable = false
        }
        await observation.record(
            scratchExisted: scratchExisted,
            scratchWasInsideWorkingCopy: inside,
            experimentWasWritable: writable,
            scratchRelativePath: relative
        )
        try "implemented\n".write(
            to: task.directory.appending(path: "app.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private actor RunObservation {
    private var scratchExisted = false
    private var insideWorkingCopy = false
    private var writable = false
    private var relativePath = ""

    func record(
        scratchExisted: Bool,
        scratchWasInsideWorkingCopy: Bool,
        experimentWasWritable: Bool,
        scratchRelativePath: String
    ) {
        self.scratchExisted = scratchExisted
        insideWorkingCopy = scratchWasInsideWorkingCopy
        writable = experimentWasWritable
        relativePath = scratchRelativePath
    }

    func result(submittedFiles: [String]) -> RunResult {
        RunResult(
            scratchExistedWhenRunStarted: scratchExisted,
            scratchWasInsideWorkingCopy: insideWorkingCopy,
            experimentWasWritable: writable,
            scratchRelativePath: relativePath,
            submittedFiles: submittedFiles
        )
    }
}

private struct RunResult: Sendable {
    let scratchExistedWhenRunStarted: Bool
    let scratchWasInsideWorkingCopy: Bool
    let experimentWasWritable: Bool
    let scratchRelativePath: String
    let submittedFiles: [String]
}
