import AgentOSCore
import Foundation

public struct SwiftAcceptanceTestPreflight: AcceptanceTestPreflight {
    public static let command = ["swift", "build", "--build-tests"]

    public init() {}

    public func compileTests(
        in directory: URL,
        testFolder: String,
        expectedAPI: [String]
    ) async -> AcceptanceTestPreflightResult {
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(
                "/usr/bin/env",
                Array(Self.command),
                in: directory
            )
        } catch {
            return .skipped
        }
        guard result.status != 0 else { return .compiled }
        let classified = Self.classify(
            log: result.output,
            in: directory,
            testFolder: testFolder,
            expectedAPI: expectedAPI
        )
        return classified.testAuthorMistakes.isEmpty
            ? .compiled
            : .diagnostics(classified.diagnostics, fullLog: result.output)
    }

    public struct Classification: Sendable {
        public let diagnostics: [CompilerDiagnostic]
        public var testAuthorMistakes: [CompilerDiagnostic] {
            diagnostics.filter { $0.classification == .testAuthorMistake }
        }
    }

    public static func classify(
        log: String,
        in root: URL,
        testFolder: String,
        expectedAPI: [String]
    ) -> Classification {
        let diagnostics = log.split(separator: "\n").compactMap { line -> CompilerDiagnostic? in
            guard let parsed = parse(String(line), root: root) else { return nil }
            let classification = classify(
                message: parsed.message,
                root: root,
                testFolder: testFolder,
                expectedAPI: expectedAPI
            )
            return CompilerDiagnostic(
                file: parsed.file,
                line: parsed.line,
                message: parsed.message,
                classification: classification
            )
        }
        return Classification(diagnostics: diagnostics)
    }

    private static func parse(_ line: String, root: URL) -> (file: String, line: Int, message: String)? {
        let pattern = #"^(.+?):(\d+)(?::\d+)?: error: (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let fileRange = Range(match.range(at: 1), in: line),
              let lineRange = Range(match.range(at: 2), in: line),
              let messageRange = Range(match.range(at: 3), in: line),
              let number = Int(line[lineRange])
        else {
            return nil
        }
        let path = String(line[fileRange])
        let prefix = root.standardizedFileURL.path + "/"
        return (
            path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path,
            number,
            String(line[messageRange])
        )
    }

    private static func classify(
        message: String,
        root: URL,
        testFolder: String,
        expectedAPI: [String]
    ) -> CompilerDiagnosticClassification {
        if isSyntaxError(message) { return .testAuthorMistake }

        let quoted = quotedSymbols(in: message)
        if quoted.contains(where: { isDeclared($0, under: root.appending(path: testFolder)) }) {
            return .testAuthorMistake
        }

        if let member = memberReference(in: message) {
            if expectedAPI.contains(where: { api in
                api.contains(member.type) && api.contains(member.member)
            }) {
                return .expected
            }
            if isProductionType(member.type, under: root) {
                return .testAuthorMistake
            }
        }

        if matchesMissingProductionAPIPattern(message) {
            if expectedAPI.contains(where: { api in quoted.contains(where: api.contains) }) {
                return .expected
            }
            return .expected
        }

        return .expected
    }

    private static func isSyntaxError(_ message: String) -> Bool {
        let fragments = [
            "expected expression", "expected declaration", "expected statement",
            "expected identifier", "consecutive statements", "unterminated string literal",
            "extraneous '}'", "expected '}'", "expected ')' after",
        ]
        return fragments.contains { message.localizedCaseInsensitiveContains($0) }
    }

    private static func matchesMissingProductionAPIPattern(_ message: String) -> Bool {
        let fragments = [
            "cannot find '", "cannot find type '", "has no member '", "no such module '",
            "missing argument label ", "no exact matches in call to initializer",
        ]
        return fragments.contains { message.contains($0) }
    }

    private static func memberReference(in message: String) -> (type: String, member: String)? {
        let patterns = [
            #"value of type '([^']+)' has no member '([^']+)'"#,
            #"type '([^']+)' has no member '([^']+)'"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let typeRange = Range(match.range(at: 1), in: message),
                  let memberRange = Range(match.range(at: 2), in: message)
            else {
                continue
            }
            return (String(message[typeRange]), String(message[memberRange]))
        }
        return nil
    }

    private static func quotedSymbols(in message: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"'([^']+)'"#) else { return [] }
        return regex.matches(in: message, range: NSRange(message.startIndex..., in: message)).compactMap {
            Range($0.range(at: 1), in: message).map { String(message[$0]) }
        }
    }

    private static func isProductionType(_ symbol: String, under root: URL) -> Bool {
        isDeclared(symbol, under: root.appending(path: "Sources"))
    }

    private static func isDeclared(_ symbol: String, under directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(?:struct|class|enum|protocol|actor|typealias|func|let|var)\s+"# + escaped + #"\b"#
        ) else {
            return false
        }
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
                return true
            }
        }
        return false
    }
}
