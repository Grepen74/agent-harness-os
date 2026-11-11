import Foundation

public enum CheckFailureKind: Sendable, Equatable {
    case reportedFailure
    case runnerCrash(signal: Int32?)
}

public struct CheckOutput: Sendable {
    public let passed: Bool
    /// One line, stable for the same failure (used for no-progress detection).
    public let summary: String
    public let log: String
    /// Test targets with failures, i.e. whose node's behaviour is broken (doc 08 §5). Empty if unknown.
    public let failingTargets: Set<String>
    public let failureKind: CheckFailureKind

    public init(
        passed: Bool,
        summary: String,
        log: String,
        failingTargets: Set<String> = [],
        failureKind: CheckFailureKind = .reportedFailure
    ) {
        self.passed = passed
        self.summary = summary
        self.log = log
        self.failingTargets = failingTargets
        self.failureKind = failureKind
    }
}

/// The checks a repo offers (its "verification ladder", doc 01). Here: one rung.
public protocol CheckRunner: Sendable {
    /// Runs all tests in the package, or only one node's test target.
    func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput
}
