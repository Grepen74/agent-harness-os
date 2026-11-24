import AgentOSCore
import Foundation

/// Evaluates the scripted agents' facts without launching another Swift build.
actor WorkflowScenarioChecks: CheckRunner {
    let splitCombinedBatch: Bool
    private var failingBatchDirectory: URL?

    init(splitCombinedBatch: Bool) {
        self.splitCombinedBatch = splitCombinedBatch
    }

    func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
        do {
            let tests = directory.appending(path: "Tests")
            let targets = FileManager.default.fileExists(atPath: tests.path)
                ? try FileManager.default.contentsOfDirectory(atPath: tests.path) : []
            var failing: Set<String> = []
            for target in targets where testTarget == nil || testTarget == target {
                let file = tests.appending(path: "\(target)/\(target).swift")
                let text = try String(contentsOf: file, encoding: .utf8)
                for match in text.matches(of: /#expect\((\w+)\.facts\["([^"]*)"\] == "([^"]*)"\)/) {
                    let (component, key, value) = (String(match.output.1), String(match.output.2), String(match.output.3))
                    let facts = ScriptedFacts.read(ScriptedFacts.sourceFile(component, in: directory))
                    if facts[key]?.value != value { failing.insert(target) }
                }
            }
            // Only the combined full check fails. Isolated suites and the baseline pass,
            // so the controller has no single owner to blame and bisects the batch.
            if splitCombinedBatch && testTarget == nil,
               directory.deletingLastPathComponent().lastPathComponent == "snapshots",
               !ScriptedFacts.read(ScriptedFacts.sourceFile("FirstFeature", in: directory)).isEmpty,
               !ScriptedFacts.read(ScriptedFacts.sourceFile("SecondFeature", in: directory)).isEmpty {
                if failingBatchDirectory == nil { failingBatchDirectory = directory }
                if failingBatchDirectory == directory { failing.insert("CombinedIntegrationTests") }
            }
            return CheckOutput(
                passed: failing.isEmpty, summary: failing.isEmpty ? "All facts passed" : "Facts failed",
                log: failing.sorted().joined(separator: "\n"), failingTargets: failing)
        } catch {
            return CheckOutput(passed: false, summary: "Could not read scenario tests: \(error)",
                               log: "\(error)", failureKind: .runnerCrash(signal: nil))
        }
    }
}

actor WorkflowReportingImplementer: Implementer {
    private var reported = false

    func implement(_ task: AgentTask) async throws -> AgentReport {
        if !reported {
            reported = true
            return AgentReport(brokenTest: BrokenTestReport(
                testName: "\(task.spec.testTarget).criterion1",
                reason: "The acceptance test needs its author's clarification before implementation."))
        }
        return try await ScriptedImplementer().implement(task)
    }
}

struct WorkflowConflictingRepository: RequirementBranchRepository {
    let defaultBranch = "main"
    func requirementBranch(for ticket: String) -> String { "agentos/\(ticket)" }
    func tip(of branch: String) async throws -> String? {
        branch == defaultBranch ? "advanced-main" : "requirement-tip"
    }
    func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool { ancestor == descendant }
    func mergeMain(_ main: String, into branch: String) async throws -> RebaseResult {
        .conflict(files: ["Sources/Greeting/Greeting.swift"])
    }
    func changedFiles(in commit: String) async throws -> [String] { ["Sources/Greeting/Greeting.swift"] }
}
