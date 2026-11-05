import AgentOSCore
import Foundation

/// Runs the commands a repo's config names: prepare, build, test, then any extra checks, each through
/// `/bin/sh -c` in the checkout. Stops at the first failure. The production equivalent is the repo's CI
/// pipeline (doc 08 §6); this is the same contract, run locally.
public struct CommandCheckRunner: CheckRunner {
    public struct Step: Sendable, Equatable {
        public let name: String
        public let command: String
    }

    public let config: RepoConfig
    public let timeout: Duration

    public init(config: RepoConfig, timeout: Duration = .seconds(1800)) {
        self.config = config
        self.timeout = timeout
    }

    /// The commands in order. `only` names one test suite; it's substituted into `test.only`.
    public func steps(only suite: String? = nil) -> [Step] {
        var steps: [Step] = []
        if let prepare = config.build?.prepare { steps.append(Step(name: "prepare", command: prepare)) }
        if let build = config.build?.command { steps.append(Step(name: "build", command: build)) }
        var test = config.test.command
        if let suite, let only = config.test.only {
            test += " " + only.replacingOccurrences(of: "{suite}", with: suite)
        }
        steps.append(Step(name: "test", command: test))
        // A single leaf's run skips the repo-wide extra checks; they run on landing.
        if suite == nil {
            steps += (config.checks ?? []).map { Step(name: $0.name, command: $0.command) }
        }
        return steps
    }

    public func runChecks(in directory: URL, only suite: String?) async -> CheckOutput {
        var log = ""
        for step in steps(only: suite) {
            log += "$ \(step.command)\n"
            let result: ProcessRunner.Result
            do {
                result = try await ProcessRunner.run("/bin/sh", ["-c", step.command], in: directory, timeout: timeout)
            } catch {
                log += "\(error)\n"
                return CheckOutput(passed: false, summary: "\(step.name): could not run: \(error)", log: log)
            }
            log += result.output
            if !result.output.hasSuffix("\n") && !result.output.isEmpty { log += "\n" }
            guard result.status == 0 else {
                log += "exit status \(result.status)\n"
                let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return CheckOutput(passed: false,
                                   summary: "\(step.name) failed: "
                                       + (trimmed.isEmpty ? "exit status \(result.status)" : SwiftPMCheckRunner.summarize(trimmed)),
                                   log: log, failingTargets: SwiftPMCheckRunner.failingTargets(in: result.output))
            }
        }
        return CheckOutput(passed: true, summary: steps(only: suite).map(\.name).joined(separator: ", ") + " passed", log: log)
    }
}

/// Runs the configured checks on a clean export of the default branch, outside the repo
/// (`<storage>/baseline/src`), so neither your checkout nor the repo's build folders are touched.
public struct BaselineRunner: Sendable {
    public let storage: URL

    public init(storage: URL) { self.storage = storage }

    public func run(config: RepoConfig, commit: String, repo root: URL) async -> Baseline {
        let started = ContinuousClock.now
        func seconds() -> Int { Int((ContinuousClock.now - started).components.seconds) }
        let source = storage.appending(path: "baseline/src", directoryHint: .isDirectory)
        let archive = storage.appending(path: "baseline/src.tar")
        let output: CheckOutput
        do {
            try? FileManager.default.removeItem(at: source)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try await Self.succeed("/usr/bin/env", ["git", "archive", "--format=tar", "-o", archive.path, commit], in: root)
            try await Self.succeed("/usr/bin/tar", ["-xf", archive.path, "-C", source.path], in: root)
            try? FileManager.default.removeItem(at: archive)
            output = await CommandCheckRunner(config: config).runChecks(in: source, only: nil)
        } catch {
            output = CheckOutput(passed: false, summary: "could not export \(commit.prefix(8)): \(error)", log: "\(error)")
        }
        let store = FileArtifactStore(directory: storage.appending(path: "artifacts", directoryHint: .isDirectory))
        let log = try? store.put(named: "baseline-\(commit.prefix(8)).log", contents: Data(output.log.utf8))
        return Baseline(commit: commit, passed: output.passed, summary: output.summary, seconds: seconds(), log: log)
    }

    struct CommandFailed: Error, CustomStringConvertible {
        let description: String
    }

    private static func succeed(_ executable: String, _ arguments: [String], in directory: URL) async throws {
        let result = try await ProcessRunner.run(executable, arguments, in: directory, timeout: .seconds(300))
        guard result.status == 0 else {
            throw CommandFailed(description: "\(arguments.joined(separator: " ")): \(result.output.prefix(300))")
        }
    }
}
