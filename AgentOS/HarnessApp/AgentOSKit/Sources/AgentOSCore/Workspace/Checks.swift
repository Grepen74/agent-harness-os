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
