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
    public let idleTimeout: Duration
    /// Where commands that name a simulator get one of their own; nil runs them as written.
    public let simulators: SimulatorPool?

    public init(config: RepoConfig, timeout: Duration = .seconds(1800), idleTimeout: Duration = .seconds(600),
                simulators: SimulatorPool? = nil) {
        self.config = config
        self.timeout = timeout
        self.idleTimeout = idleTimeout
        self.simulators = simulators
    }

    /// The commands in order. `only` names one test suite; it's substituted into `test.only`.
    public func steps(only suite: String? = nil) -> [Step] {
        var steps: [Step] = []
        if let prepare = config.build?.prepare { steps.append(Step(name: "prepare", command: prepare)) }
        if let build = config.build?.command { steps.append(Step(name: "build", command: build)) }
        var test = config.test.command
        if let suite, let only = config.test.only {
            test += " " + only.replacingOccurrences(of: "{suiteRegex}", with: SwiftTestSuiteSelector.shellArgument(for: suite))
                .replacingOccurrences(of: "{suite}", with: suite)
        }
        steps.append(Step(name: "test", command: test))
        // A single leaf's run skips the repo-wide extra checks; they run on landing.
        if suite == nil {
            steps += (config.checks ?? []).map { Step(name: $0.name, command: $0.command) }
        }
        return steps
    }

    /// SwiftPM's incremental build sometimes keeps object files from before a type's layout changed. Linking then
    /// fails with undefined symbols, or, when the symbols still match, the test process crashes (e.g. signal 11)
    /// although the code is fine. No agent can fix that; a clean build can.
    public static func isStaleBuildFailure(_ output: String) -> Bool {
        let linkFailed = output.contains("Undefined symbols for architecture")
            && (output.contains("link command failed") || output.contains("linker command failed"))
        return linkFailed || output.contains("exited with unexpected signal code")
    }

    /// Removes every `.build` folder in the checkout, outside `.git`. Returns the ones removed.
    @discardableResult
    public static func removeBuildFolders(in directory: URL) -> [URL] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if url.lastPathComponent == ".git" { walker.skipDescendants() }
            if url.lastPathComponent == ".build" {
                walker.skipDescendants()
                found.append(url)
            }
        }
        return found.filter { (try? manager.removeItem(at: $0)) != nil }
    }

    /// Without `test.only`, a run of one suite runs all tests.
    public var selectsSuites: Bool { config.test.only != nil }

    /// The checks check what's committed, so tracked files they change (a project the prepare step generates
    /// differently from the committed one, say) are put back afterwards: otherwise the checkout is no longer
    /// clean, and landing it stops. Files already changed before the checks are left alone.
    public func runChecks(in directory: URL, only suite: String?) async -> CheckOutput {
        let changedBefore = await Self.trackedChanges(in: directory)
        let output = await runSteps(in: directory, only: suite)
        guard let changedBefore else { return output }
        // Not cancelled with the checks: the checkout is put back either way.
        let note = await Task { await Self.restoreTrackedFiles(changedSince: changedBefore, in: directory) }.value
        guard let note else { return output }
        return CheckOutput(passed: output.passed, summary: output.summary, log: output.log + note + "\n",
                           failingTargets: output.failingTargets, failureKind: output.failureKind, checks: output.checks)
    }

    /// Tracked files with staged or unstaged changes, or nil when the directory isn't the top of a git checkout.
    static func trackedChanges(in directory: URL) async -> Set<String>? {
        guard let prefix = try? await ProcessRunner.run("/usr/bin/env", ["git", "rev-parse", "--show-prefix"],
                                                        in: directory, timeout: .seconds(60)),
              prefix.status == 0, prefix.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let status = try? await ProcessRunner.run(
                  "/usr/bin/env", ["git", "status", "--porcelain=v1", "-z", "--untracked-files=no", "--no-renames"],
                  in: directory, timeout: .seconds(60)),
              status.status == 0 else { return nil }
        // Each entry is "XY path": X for the index, Y for the working tree.
        return Set(status.output.split(separator: "\0").filter { $0.count > 3 }.map { String($0.dropFirst(3)) })
    }

    /// Puts back the tracked files changed since `before`. Returns a line for the log, or nil if none changed.
    static func restoreTrackedFiles(changedSince before: Set<String>, in directory: URL) async -> String? {
        guard let after = await trackedChanges(in: directory) else { return nil }
        let changed = after.subtracting(before).sorted()
        guard !changed.isEmpty else { return nil }
        let files = changed.joined(separator: ", ")
        let restore = try? await ProcessRunner.run(
            "/usr/bin/env", ["git", "restore", "--source=HEAD", "--staged", "--worktree", "--"] + changed.map { ":(literal)" + $0 },
            in: directory, timeout: .seconds(60))
        guard let restore, restore.status == 0 else {
            return "Couldn't put back the tracked files the checks changed (\(files)): "
                + (restore?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "git restore didn't run")
        }
        return "Put back \(changed.count) tracked file(s) the checks changed, so the checkout stays as committed: \(files)"
    }

    private func runSteps(in directory: URL, only suite: String?) async -> CheckOutput {
        var log = ""
        var completed: [CheckResult] = []
        var cleaned = false
        var pending = steps(only: suite)
        while !pending.isEmpty {
            let step = pending.removeFirst()
            let result: ProcessRunner.Result
            do {
                let run: @Sendable (String) async throws -> (String, ProcessRunner.Result) = { [timeout, idleTimeout] command in
                    (command, try await ProcessRunner.run("/bin/sh", ["-c", command], in: directory,
                                                          timeout: timeout, idleTimeout: idleTimeout))
                }
                let (command, output) = if let simulators {
                    try await simulators.withSimulator(for: step.command, run)
                } else {
                    try await run(step.command)
                }
                log += "$ \(command)\n"
                result = output
            } catch {
                log += "$ \(step.command)\n"
                log += "\(error)\n"
                let summary = "\(step.name): could not run: \(error)"
                return CheckOutput(passed: false, summary: summary, log: log,
                                   checks: completed + [CheckResult(name: step.name, passed: false, summary: summary)])
            }
            log += result.output
            if !result.output.hasSuffix("\n") && !result.output.isEmpty { log += "\n" }
            if result.idleTimedOut {
                let summary = "\(step.name) hung: no output for \(idleTimeout)"
                log += summary + "\n"
                return CheckOutput(passed: false, summary: summary, log: log, failureKind: .runnerCrash(signal: SIGKILL),
                                   checks: completed + [CheckResult(name: step.name, passed: false, summary: summary)])
            }
            guard result.status == 0 else {
                log += "exit status \(result.status)\n"
                if !cleaned && Self.isStaleBuildFailure(result.output) {
                    cleaned = true
                    let removed = Self.removeBuildFolders(in: directory)
                    log += "Possibly stale build output (link failure or test crash): removed \(removed.count) .build folder(s); running \(step.name) again.\n"
                    pending.insert(step, at: 0)
                    continue
                }
                let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = "\(step.name) failed: "
                    + (trimmed.isEmpty ? "exit status \(result.status)" : SwiftPMCheckRunner.summarize(trimmed))
                let failingTests = CheckOutput(passed: false, summary: summary, log: result.output).failingTests.sorted()
                return CheckOutput(passed: false,
                                   summary: summary,
                                   log: log, failingTargets: SwiftPMCheckRunner.failingTargets(in: result.output),
                                   failureKind: result.crashSignal.map { .runnerCrash(signal: $0) } ?? .reportedFailure,
                                   checks: completed + [CheckResult(name: step.name, passed: false,
                                                                    summary: summary, failingTests: failingTests)])
            }
            completed.append(CheckResult(name: step.name, passed: true,
                                         summary: "\(step.name) passed (exit status 0)"))
        }
        return CheckOutput(passed: true, summary: steps(only: suite).map(\.name).joined(separator: ", ") + " passed",
                           log: log, checks: completed)
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
