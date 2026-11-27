import Foundation

/// A small lexical scan keeps marker-like text in comments, strings and other suites out of attribution.
enum SuiteTicketMarkers {
    private struct Token {
        let text: String
        let line: Int
        let literal: Bool
    }

    static func markers(for suite: String, in source: String) -> [String] {
        guard source.contains("ticket") || source.contains("Ticket:") else { return [] }
        let (tokens, comments) = tokenize(source)
        let modifiers: Set<String> = ["public", "package", "internal", "fileprivate", "private",
                                     "final", "open", "nonisolated"]
        let declarations: Set<String> = ["struct", "class", "enum", "actor"]
        var visited: Set<Int> = []
        var result: [String] = []
        for start in tokens.indices {
            guard !tokens[start].literal else { continue }
            var index = start
            var traits: [String] = []
            var attributeLine: Int?
            while index < tokens.count {
                if tokens[index].text == "@", index + 1 < tokens.count {
                    let isSuite = tokens[index + 1].text == "Suite"
                    if isSuite { attributeLine = tokens[index].line }
                    index += 2
                    if index < tokens.count, tokens[index].text == "(" {
                        let opening = index
                        var depth = 1
                        index += 1
                        while index < tokens.count, depth > 0 {
                            if !tokens[index].literal {
                                if tokens[index].text == "(" { depth += 1 }
                                if tokens[index].text == ")" { depth -= 1 }
                            }
                            index += 1
                        }
                        if isSuite {
                            for i in opening..<max(opening, index - 4) {
                                if !tokens[i].literal, tokens[i].text == ".",
                                   !tokens[i + 1].literal, tokens[i + 1].text == "ticket",
                                   !tokens[i + 2].literal, tokens[i + 2].text == "(",
                                   tokens[i + 3].literal,
                                   !tokens[i + 4].literal, tokens[i + 4].text == ")" {
                                    traits.append(tokens[i + 3].text)
                                }
                            }
                        }
                    }
                } else if modifiers.contains(tokens[index].text) {
                    index += 1
                } else {
                    break
                }
            }
            guard index + 1 < tokens.count, !tokens[index].literal, !tokens[index + 1].literal,
                  declarations.contains(tokens[index].text),
                  tokens[index + 1].text == suite, visited.insert(index).inserted else { continue }
            let precedingLines = Set([tokens[start].line - 1, tokens[index].line - 1,
                                      attributeLine.map { $0 - 1 } ?? -1])
            for line in precedingLines.sorted() {
                if let key = comments[line] { traits.append(key) }
            }
            result.append(contentsOf: traits)
        }
        return result
    }

    private static func tokenize(_ source: String) -> ([Token], [Int: String]) {
        let chars = Array(source)
        let lines = source.components(separatedBy: "\n")
        var index = 0
        var line = 0
        var tokens: [Token] = []
        var comments: [Int: String] = [:]
        func at(_ offset: Int) -> Character? {
            index + offset < chars.count ? chars[index + offset] : nil
        }
        func advance() {
            if chars[index] == "\n" { line += 1 }
            index += 1
        }
        while index < chars.count {
            if chars[index].isWhitespace { advance(); continue }
            if at(0) == "/", at(1) == "/" {
                if let match = lines[line].firstMatch(of: /^\s*\/\/ Ticket:\s*(\S+)\s*$/) {
                    comments[line] = String(match.output.1)
                }
                while index < chars.count, chars[index] != "\n" { advance() }
                continue
            }
            if at(0) == "/", at(1) == "*" {
                advance(); advance()
                var depth = 1
                while index < chars.count, depth > 0 {
                    if at(0) == "/", at(1) == "*" { advance(); advance(); depth += 1 }
                    else if at(0) == "*", at(1) == "/" { advance(); advance(); depth -= 1 }
                    else { advance() }
                }
                continue
            }
            let start = index
            let startLine = line
            var hashes = 0
            while at(hashes) == "#" { hashes += 1 }
            if at(hashes) == "\"" {
                for _ in 0..<hashes { advance() }
                let multiline = at(1) == "\"" && at(2) == "\""
                let quotes = multiline ? 3 : 1
                for _ in 0..<quotes { advance() }
                let contents = index
                var end = index
                while index < chars.count {
                    let closes = (0..<quotes).allSatisfy { at($0) == "\"" }
                        && (quotes..<(quotes + hashes)).allSatisfy { at($0) == "#" }
                    if closes {
                        end = index
                        for _ in 0..<(quotes + hashes) { advance() }
                        break
                    }
                    if at(0) == "\\", (1..<(hashes + 1)).allSatisfy({ at($0) == "#" }) {
                        for _ in 0..<(hashes + 1) { advance() }
                        if index < chars.count { advance() }
                    } else { advance() }
                    end = index
                }
                // Only plain, unescaped string arguments can be a ticket key.
                let text = String(chars[contents..<end])
                tokens.append(Token(text: hashes == 0 && !multiline && !text.contains("\\") ? text : "",
                                    line: startLine, literal: true))
            } else if chars[index].isLetter || chars[index] == "_" {
                while index < chars.count,
                      chars[index].isLetter || chars[index].isNumber || chars[index] == "_" { advance() }
                tokens.append(Token(text: String(chars[start..<index]), line: startLine, literal: false))
            } else {
                tokens.append(Token(text: String(chars[index]), line: line, literal: false))
                advance()
            }
        }
        return (tokens, comments)
    }
}
