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
        await compileTests(in: directory, testFolder: testFolder, testFiles: nil, expectedAPI: expectedAPI)
    }

    public func compileTests(
        in directory: URL,
        testFolder: String,
        testFiles: [String]?,
        expectedAPI: [String]
    ) async -> AcceptanceTestPreflightResult {
        let broken = Self.testRuleFindings(in: directory, testFolder: testFolder, testFiles: testFiles)
        if !broken.isEmpty {
            return .diagnostics(broken, fullLog: broken.map { "\($0.file):\($0.line): \($0.message)" }.joined(separator: "\n"))
        }
        guard let package = Self.packageRoot(for: testFiles?.first ?? testFolder, in: directory) else { return .skipped }
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(
                "/usr/bin/env",
                Array(Self.command),
                in: package
            )
        } catch {
            return .skipped
        }
        guard result.status != 0 else { return .compiled }
        let classified = Self.classify(
            log: result.output,
            in: directory,
            testFolder: testFolder,
            testFiles: testFiles,
            expectedAPI: expectedAPI
        )
        return classified.testAuthorMistakes.isEmpty
            ? .compiled
            : .diagnostics(classified.diagnostics, fullLog: result.output)
    }

    /// What makes a test pass or fail with the machine's load rather than the code: a fixed wait, a delayed
    /// dispatch, a time limit or a measured duration. And comparing a whole list of cases, which fails every later
    /// ticket that adds one. Rules look at code only, not comments or strings, unless `inStrings` says so.
    static let testRules: [(pattern: String, problem: String, inStrings: Bool)] = [
        (#"\b(?:Task|Thread)\.sleep\b|(?<!func )(?<![\w.])u?sleep\s*\(|\.sleep\s*\(\s*(?:for|until)\s*:"#,
         "a fixed sleep. Hold fake agents at a barrier the test opens, or wait for a condition", false),
        (#"\.asyncAfter\s*\("#, "a delayed dispatch. Hold fake agents at a barrier the test opens instead", false),
        (#"\.timeLimit\s*\("#, "a time limit, which fails healthy runs on a busy machine", false),
        (#"#(?:expect|require)\b.*(?:\.timeIntervalSince\s*\(|\.timeIntervalSinceNow\b|\.measure\s*[({]|\.duration\s*\(\s*to\s*:)"#,
         "an assertion on how long something took. Inject a clock if the code reads the time", false),
        (#"\ballCases\s*==|==\s*[\w.()\[\]]*\.allCases\b"#,
         "a comparison of all cases, which fails every later change that adds one. Check with contains", false),
        (#"\.agentos/scratch/run-"#, "a path in one agent run's scratch folder, which is gone after that run", true),
    ]

    /// The test rules the Swift files in the test folder break, comments aside.
    public static func testRuleFindings(
        in root: URL, testFolder: String, testFiles: [String]? = nil
    ) -> [CompilerDiagnostic] {
        let rules = testRules.compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern)).map { ($0, rule.problem, rule.inStrings) }
        }
        var findings: [CompilerDiagnostic] = []
        for path in ownTestFiles(in: root, testFolder: testFolder, testFiles: testFiles) {
            let file = root.appending(path: path)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let withStrings = blankingComments(in: text, andStrings: false)
                .split(separator: "\n", omittingEmptySubsequences: false)
            let code = blankingComments(in: text, andStrings: true).split(separator: "\n", omittingEmptySubsequences: false)
            for number in code.indices {
                for (regex, problem, inStrings) in rules {
                    let line = String(inStrings ? withStrings[number] : code[number])
                    guard regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                    findings.append(CompilerDiagnostic(
                        file: path, line: number + 1, message: CompilerDiagnostic.testRulePrefix + problem,
                        classification: .testAuthorMistake
                    ))
                }
            }
        }
        return findings
    }

    private static func ownTestFiles(in root: URL, testFolder: String, testFiles: [String]?) -> [String] {
        if let testFiles {
            return Set(testFiles).filter { $0.hasSuffix(".swift") }.sorted()
        }
        let folder = root.appending(path: testFolder)
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        let prefix = folder.standardizedFileURL.path + "/"
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            .map { testFolder + "/" + $0.standardizedFileURL.path.dropFirst(prefix.count) }.sorted()
    }

    /// `text` with comments (and the contents of string literals if `andStrings`) replaced by spaces, keeping
    /// line breaks so line numbers stay the same. Interpolations count as part of their string.
    static func blankingComments(in text: String, andStrings: Bool) -> String {
        enum Mode { case code, lineComment, blockComment(depth: Int), string(multiline: Bool) }
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)
        var mode = Mode.code
        var index = 0
        func blank(_ character: Character) -> Character { character.isNewline ? character : " " }
        func starts(with token: String) -> Bool {
            let token = Array(token)
            return index + token.count <= characters.count && Array(characters[index..<index + token.count]) == token
        }
        while index < characters.count {
            let character = characters[index]
            switch mode {
            case .code:
                if starts(with: "//") {
                    mode = .lineComment
                    result += "  "; index += 2; continue
                } else if starts(with: "/*") {
                    mode = .blockComment(depth: 1)
                    result += "  "; index += 2; continue
                } else if starts(with: "\"\"\"") {
                    mode = .string(multiline: true)
                    result += "\"\"\""; index += 3; continue
                } else if character == "\"" {
                    mode = .string(multiline: false)
                }
                result.append(character)
            case .lineComment:
                if character.isNewline { mode = .code }
                result.append(blank(character))
            case .blockComment(let depth):
                if starts(with: "*/") {
                    mode = depth == 1 ? .code : .blockComment(depth: depth - 1)
                    result += "  "; index += 2; continue
                } else if starts(with: "/*") {
                    mode = .blockComment(depth: depth + 1)
                    result += "  "; index += 2; continue
                }
                result.append(blank(character))
            case .string(let multiline):
                if character == "\\", index + 1 < characters.count {
                    result += andStrings ? "  " : String(characters[index...index + 1])
                    index += 2; continue
                } else if multiline ? starts(with: "\"\"\"") : character == "\"" {
                    mode = .code
                    result += multiline ? "\"\"\"" : "\""
                    index += multiline ? 3 : 1; continue
                } else if !multiline, character.isNewline {
                    mode = .code
                }
                result.append(andStrings ? blank(character) : character)
            }
            index += 1
        }
        return result
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
        testFiles: [String]? = nil,
        expectedAPI: [String]
    ) -> Classification {
        let diagnostics = log.split(separator: "\n").compactMap { line -> CompilerDiagnostic? in
            guard let parsed = parse(String(line), root: root) else { return nil }
            let classification = classify(
                message: parsed.message,
                root: root,
                testFolder: testFolder,
                testFiles: testFiles,
                expectedAPI: expectedAPI
            )
            return CompilerDiagnostic(
                file: parsed.file,
                line: parsed.line,
                message: parsed.message,
                classification: classification
            )
        }
        return Classification(diagnostics: diagnostics + sameNamedFiles(
            in: log, root: root, testFolder: testFolder, testFiles: testFiles))
    }

    /// SwiftPM names each object file after its source file, so two same-named files in one target stop the whole
    /// build ("multiple producers") without pointing at a source line. When one of them is the tests' own, renaming
    /// it is the test author's job.
    private static func sameNamedFiles(
        in log: String, root: URL, testFolder: String, testFiles: [String]?
    ) -> [CompilerDiagnostic] {
        guard let regex = try? NSRegularExpression(pattern: #"couldn't build .*/([^/]+\.swift)\.o because of multiple producers"#)
        else { return [] }
        let names = Set(regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).compactMap {
            Range($0.range(at: 1), in: log).map { String(log[$0]) }
        })
        guard !names.isEmpty else { return [] }
        let package = packageRoot(for: testFiles?.first ?? testFolder, in: root) ?? root
        let prefix = root.standardizedFileURL.path + "/"
        var found: [String: [String]] = [:]
        if let enumerator = FileManager.default.enumerator(at: package.appending(path: "Tests"),
                                                           includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator where names.contains(file.lastPathComponent) {
                let path = file.standardizedFileURL.path
                found[file.lastPathComponent, default: []].append(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)
            }
        }
        let own = Set(ownTestFiles(in: root, testFolder: testFolder, testFiles: testFiles))
        return names.sorted().flatMap { name -> [CompilerDiagnostic] in
            let paths = (found[name] ?? []).sorted()
            return paths.filter { own.contains($0) }.map { path in
                CompilerDiagnostic(
                    file: path, line: 1,
                    message: "another file in the same test target is also named \(name) ("
                        + paths.filter { $0 != path }.joined(separator: ", ")
                        + "), so the target can't build. Rename yours to a name unique to this work item, "
                        + "e.g. prefixed with the suite name",
                    classification: .testAuthorMistake)
            }
        }
    }

    /// The Swift package the test folder belongs to: the nearest folder at or above it, within the working copy,
    /// that has a Package.swift. The package is often not at the top of the repo.
    public static func packageRoot(for testFolder: String, in root: URL) -> URL? {
        var components = testFolder.split(separator: "/").map(String.init)
        while true {
            let folder = components.reduce(root) { $0.appending(path: $1) }
            if FileManager.default.fileExists(atPath: folder.appending(path: "Package.swift").path) { return folder }
            if components.isEmpty { return nil }
            components.removeLast()
        }
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
        testFiles: [String]?,
        expectedAPI: [String]
    ) -> CompilerDiagnosticClassification {
        if isSyntaxError(message) || isOwnNamingMistake(message) || isMisplacedTest(message) { return .testAuthorMistake }
        // The quoted names are argument labels, not symbols, so a test local of the same name says nothing: a call
        // to a signature the change hasn't added yet.
        if isArgumentMismatch(message) { return .expected }

        let quoted = quotedSymbols(in: message)
        let member = memberReference(in: message)
        // For a missing member only its type can be the tests' own: tests often name locals after the member.
        let ownCandidates = member.map { [$0.type] } ?? quoted
        let ownFiles = ownTestFiles(in: root, testFolder: testFolder, testFiles: testFiles).map { root.appending(path: $0) }
        if ownCandidates.contains(where: { isDeclared($0, in: ownFiles) }) {
            return .testAuthorMistake
        }

        if let member {
            if expectedAPI.contains(where: { api in
                api.contains(member.type) && api.contains(member.member)
            }) {
                return .expected
            }
            // Expected on a protocol or supertype, e.g. `Workspace.prepareRequirementBranch` called on a conforming type.
            if expectedAPI.contains(where: { names(member.member, asMemberIn: $0) }) {
                return .expected
            }
            if isProductionType(member.type, under: root, testFolder: testFiles?.first ?? testFolder) {
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

    /// Names that clash with existing ones: missing code can't cause these, so the tests themselves are wrong.
    private static func isOwnNamingMistake(_ message: String) -> Bool {
        ["is ambiguous for type lookup", "ambiguous use of '", "invalid redeclaration of '"].contains { message.contains($0) }
    }

    /// A test declared where Swift Testing can't run it, e.g. nested in another test by a misplaced brace.
    private static func isMisplacedTest(_ message: String) -> Bool {
        message.contains("Attribute 'Test' cannot be applied") || message.contains("Attribute 'Suite' cannot be applied")
    }

    private static func isArgumentMismatch(_ message: String) -> Bool {
        let fragments = [
            "extra argument '", "extra arguments at positions", "missing argument for parameter '",
            "missing arguments for parameters '", "incorrect argument label", "argument passed to call that takes no arguments",
            "extraneous argument label '",
        ]
        return fragments.contains { message.contains($0) }
    }

    private static func names(_ member: String, asMemberIn api: String) -> Bool {
        let pattern = #"\."# + NSRegularExpression.escapedPattern(for: member) + #"(?![A-Za-z0-9_])"#
        return api.range(of: pattern, options: .regularExpression) != nil
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

    private static func isProductionType(_ symbol: String, under root: URL, testFolder: String) -> Bool {
        isDeclared(symbol, under: (packageRoot(for: testFolder, in: root) ?? root).appending(path: "Sources"))
    }

    private static func isDeclared(_ symbol: String, under directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return isDeclared(symbol, in: enumerator.compactMap { $0 as? URL })
    }

    private static func isDeclared(_ symbol: String, in files: [URL]) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(?:struct|class|enum|protocol|actor|typealias|func|let|var)\s+"# + escaped + #"\b"#
        ) else {
            return false
        }
        for file in files where file.pathExtension == "swift" {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
                return true
            }
        }
        return false
    }
}
