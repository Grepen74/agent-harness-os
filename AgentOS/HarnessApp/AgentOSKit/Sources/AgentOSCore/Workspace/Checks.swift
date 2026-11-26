import Foundation

public enum CheckFailureKind: Sendable, Equatable {
    case reportedFailure
    case runnerCrash(signal: Int32?)
}

/// The reported source file and suite of a failure; either may be unknown.
public struct CheckFailureLocation: Sendable, Equatable {
    public let file: String?
    public let suite: String?

    public init(file: String? = nil, suite: String? = nil) {
        self.file = file
        self.suite = suite
    }
}

public struct CheckOutput: Sendable {
    public let passed: Bool
    /// One line, stable for the same failure (used for no-progress detection).
    public let summary: String
    public let log: String
    /// Test targets with failures, i.e. whose node's behaviour is broken (doc 08 §5). Empty if unknown.
    public let failingTargets: Set<String>
    public let failureLocations: [CheckFailureLocation]
    public let failureKind: CheckFailureKind
    public let checks: [CheckResult]

    public init(
        passed: Bool,
        summary: String,
        log: String,
        failingTargets: Set<String> = [],
        failureKind: CheckFailureKind = .reportedFailure,
        checks: [CheckResult] = [],
        failureLocations: [CheckFailureLocation] = []
    ) {
        self.passed = passed
        self.summary = summary
        self.log = log
        self.failingTargets = failingTargets
        self.failureLocations = passed ? [] : failureLocations
        self.failureKind = failureKind
        self.checks = checks
    }

    /// The tests the log names as failing, as `Suite.test`: Swift Testing's "Test name(…) recorded an issue … at
    /// Suite.swift:line" and XCTest's "Test Case '-[Module.Suite test]' failed". Empty when it names none.
    public var failingTests: Set<String> {
        var tests: Set<String> = []
        for line in log.split(separator: "\n") {
            if let match = line.firstMatch(of: /Test (\w+)\(.*recorded an issue.* at (\w+)\.swift:\d+/) {
                tests.insert("\(match.output.2).\(match.output.1)")
            } else if let match = line.firstMatch(of: /Test Case '-\[(?:\w+\.)?(\w+) (\w+)\]' failed/) {
                tests.insert("\(match.output.1).\(match.output.2)")
            }
        }
        return tests
    }
}

/// The checks a repo offers (its "verification ladder", doc 01). Here: one rung.
public protocol CheckRunner: Sendable {
    /// Runs all tests in the package, or only one node's test target.
    func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput
    /// Whether `only` really runs just that suite. If not, it runs all tests.
    var selectsSuites: Bool { get }
}

public extension CheckRunner {
    var selectsSuites: Bool { true }
}
