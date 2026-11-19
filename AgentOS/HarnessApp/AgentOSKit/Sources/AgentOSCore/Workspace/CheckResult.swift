/// One configured check within a verification run; its full output shares the run's artifact.
public struct CheckResult: Codable, Sendable, Hashable {
    public let name: String
    public let passed: Bool
    public let summary: String
    public let failingTests: [String]

    public init(name: String, passed: Bool, summary: String, failingTests: [String] = []) {
        self.name = name
        self.passed = passed
        self.summary = summary
        self.failingTests = failingTests
    }
}
