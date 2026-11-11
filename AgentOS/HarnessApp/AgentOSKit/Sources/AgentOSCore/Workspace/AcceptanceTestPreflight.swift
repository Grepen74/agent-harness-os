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
