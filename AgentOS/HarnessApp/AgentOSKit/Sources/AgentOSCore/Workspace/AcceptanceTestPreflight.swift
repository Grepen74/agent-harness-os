import Foundation

public enum CompilerDiagnosticClassification: String, Codable, Sendable {
    case expected
    case testAuthorMistake
}

public struct CompilerDiagnostic: Codable, Sendable, Hashable {
    public let file: String
    public let line: Int
    public let message: String
    public let classification: CompilerDiagnosticClassification

    /// Starts the message of a finding that breaks the test rules (a fixed sleep, say) rather than the compiler's.
    public static let testRulePrefix = "breaks the test rules: "

    public var breaksTestRules: Bool { message.hasPrefix(Self.testRulePrefix) }

    public init(file: String, line: Int, message: String, classification: CompilerDiagnosticClassification) {
        self.file = file
        self.line = line
        self.message = message
        self.classification = classification
    }
}

public enum AcceptanceTestPreflightResult: Sendable {
    case compiled
    case skipped
    case diagnostics([CompilerDiagnostic], fullLog: String)
}

public protocol AcceptanceTestPreflight: Sendable {
    func compileTests(
        in directory: URL,
        testFolder: String,
        expectedAPI: [String]
    ) async -> AcceptanceTestPreflightResult
    func compileTests(
        in directory: URL,
        testFolder: String,
        testFiles: [String]?,
        expectedAPI: [String]
    ) async -> AcceptanceTestPreflightResult
}

public extension AcceptanceTestPreflight {
    func compileTests(
        in directory: URL,
        testFolder: String,
        testFiles: [String]?,
        expectedAPI: [String]
    ) async -> AcceptanceTestPreflightResult {
        await compileTests(in: directory, testFolder: testFolder, expectedAPI: expectedAPI)
    }
}

public struct SkippedAcceptanceTestPreflight: AcceptanceTestPreflight {
    public init() {}

    public func compileTests(
        in directory: URL,
        testFolder: String,
        expectedAPI: [String]
    ) async -> AcceptanceTestPreflightResult {
        .skipped
    }
}
