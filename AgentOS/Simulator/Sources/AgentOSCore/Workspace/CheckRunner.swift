import Foundation

public struct CheckOutput: Sendable {
    public let passed: Bool
    /// One line, stable for the same failure (used for no-progress detection).
    public let summary: String
    public let log: String
    /// Test targets with failures, i.e. whose node's behaviour is broken (doc 08 §5). Empty if unknown.
    public let failingTargets: Set<String>

    public init(passed: Bool, summary: String, log: String, failingTargets: Set<String> = []) {
        self.passed = passed
        self.summary = summary
        self.log = log
        self.failingTargets = failingTargets
    }
}

/// The checks a repo offers (its "verification ladder", doc 01). Here: one rung.
public protocol CheckRunner: Sendable {
    /// Runs all tests in the package, or only one node's test target.
    func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput
}

/// Really builds and tests the package with SwiftPM.
/// Production: the repo's CI pipeline, with lint, static analysis, coverage, HIL/SIL… per policy profile,
/// and only the tests affected by the change (doc 08 §6).
public struct SwiftPMCheckRunner: CheckRunner {
    public init() {}

    public func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
        let filter = testTarget.map { ["--filter", "\($0)\\."] } ?? []
        do {
            let result = try await ProcessRunner.run("/usr/bin/env", ["swift", "test"] + filter, in: directory)
            let passed = result.status == 0
            return CheckOutput(passed: passed, summary: passed ? "swift test passed" : Self.summarize(result.output),
                               log: result.output, failingTargets: passed ? [] : Self.failingTargets(in: result.output))
        } catch {
            return CheckOutput(passed: false, summary: "could not run swift test: \(error)", log: "\(error)")
        }
    }

    /// Picks the first meaningful error line so the same failure gives the same summary.
    static func summarize(_ log: String) -> String {
        let lines = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let interesting = lines.first { $0.contains("error:") }
            ?? lines.first { $0.contains("Expectation failed") || $0.contains("recorded an issue") }
            ?? lines.last ?? "swift test failed"
        // Strip absolute paths so the summary is stable between runs.
        return String(interesting.split(separator: "/").last ?? Substring(interesting)).prefix(200).description
    }

    /// Each node's tests live in `Tests/<Target>/<Target>.swift`, so failures name their target either by
    /// folder (compile errors) or by file name (test issues).
    static func failingTargets(in log: String) -> Set<String> {
        var targets: Set<String> = []
        for line in log.split(separator: "\n") where line.contains("error") || line.contains("recorded an issue") {
            for match in line.matches(of: /Tests\/(\w+Tests)\/|(\w+Tests)\.swift:\d+/) {
                if let name = match.output.1 ?? match.output.2 { targets.insert(String(name)) }
            }
        }
        return targets
    }
}
