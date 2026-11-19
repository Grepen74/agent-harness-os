import Foundation
import Testing
import AgentOSCore

extension GH_91Tests {
    static func proofIsAssociatedWithCriterion(
        _ tests: [String], criterion: String, among criteria: [String], in body: String
    ) -> Bool {
        Self.associatedBlocks(for: criterion, among: criteria, in: body).contains { block in
            tests.allSatisfy(block.contains)
        }
    }

    static func checkIsDescribed(_ evidence: Evidence, among checks: [Evidence], in body: String) -> Bool {
        let file = URL(fileURLWithPath: evidence.artifactPath).lastPathComponent
        var fields = [evidence.check, evidence.commit, evidence.summary, file, evidence.artifactSHA256]
        if !evidence.passed, let details = evidence.details { fields.append(details) }
        return Self.associatedBlocks(for: evidence.check, among: checks.map(\.check), in: body).contains { block in
            fields.allSatisfy(block.contains) && Self.hasResult(evidence.passed, check: evidence.check, in: block)
        }
    }

    // A table row, list item (including nested fields), or heading section is one association.
    // Never let a following criterion/check lend its fields to the preceding one.
    private static func associatedBlocks(for label: String, among labels: [String], in body: String) -> [String] {
        let lines = body.components(separatedBy: .newlines)
        return lines.indices.compactMap { start in
            let first = lines[start]
            guard first.contains(label), !labels.contains(where: { $0 != label && first.contains($0) }) else {
                return nil
            }
            if first.contains("|") { return first }
            let heading = Self.headingLevel(first)
            let itemIndent = Self.listIndent(first)
            var end = start + 1
            while end < lines.count {
                let line = lines[end]
                if labels.contains(where: line.contains) { break }
                if let nextHeading = Self.headingLevel(line), nextHeading <= (heading ?? Int.max) { break }
                if let itemIndent, let nextIndent = Self.listIndent(line), nextIndent <= itemIndent { break }
                if heading == nil && itemIndent == nil && line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                end += 1
            }
            return lines[start..<end].joined(separator: "\n")
        }
    }

    private static func headingLevel(_ line: String) -> Int? {
        let text = line.trimmingCharacters(in: .whitespaces)
        let count = text.prefix(while: { $0 == "#" }).count
        return count > 0 && text.dropFirst(count).first == " " ? count : nil
    }

    private static func listIndent(_ line: String) -> Int? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.range(of: #"^(?:[-*+]|\d+[.)])\s+"#, options: .regularExpression) != nil else { return nil }
        return line.prefix(while: \.isWhitespace).count
    }

    private static func hasResult(_ passed: Bool, check: String, in block: String) -> Bool {
        let statuses = ["pass": true, "passed": true, "success": true, "successful": true, "succeeded": true,
                        "fail": false, "failed": false, "failure": false]
        let text = block.lowercased().filter { !"*`_".contains($0) }
        let label = NSRegularExpression.escapedPattern(for: check.lowercased().filter { !"*`_".contains($0) })
        let pattern = #"\b(?:result|status|outcome|"# + label + #")\s*[:=-]\s*(pass(?:ed)?|success(?:ful)?|succeeded|fail(?:ed|ure)?)\b"#
        let regex = try? NSRegularExpression(pattern: pattern)
        guard let regex else { return false }
        let nsText = text as NSString
        var results = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap {
            statuses[nsText.substring(with: $0.range(at: 1))]
        }
        for line in text.components(separatedBy: .newlines) {
            for cell in line.components(separatedBy: "|") {
                if let result = statuses[cell.trimmingCharacters(in: .alphanumerics.inverted)] { results.append(result) }
            }
            if let range = line.range(of: check.lowercased()) {
                let suffix = String(line[range.upperBound...]).trimmingCharacters(in: .alphanumerics.inverted)
                if let result = statuses[suffix] { results.append(result) }
            }
        }
        return results.contains(passed) && !results.contains(!passed)
    }

    static func verifyDescriptionMatchers(_ fixture: Fixture) throws {
        let criteria = fixture.root.acceptanceCriteria
        let first = fixture.proofs[0]
        let second = fixture.proofs[1]
        let table = """
            | Criterion | Tests |
            | --- | --- |
            | \(criteria[0]) | \(first.tests.joined(separator: ", ")) |
            | \(criteria[1]) | \(second.tests.joined(separator: ", ")) |
            """
        try #require(Self.proofIsAssociatedWithCriterion(first.tests, criterion: criteria[0], among: criteria, in: table))
        let swapped = """
            | Criterion | Tests |
            | --- | --- |
            | \(criteria[0]) | \(second.tests.joined(separator: ", ")) |
            | \(criteria[1]) | \(first.tests.joined(separator: ", ")) |
            """
        try #require(!Self.proofIsAssociatedWithCriterion(first.tests, criterion: criteria[0], among: criteria, in: swapped))
        let unrelated = "\(criteria.joined(separator: "\n"))\n\n\(first.tests.joined(separator: "\n"))"
        try #require(!Self.proofIsAssociatedWithCriterion(first.tests, criterion: criteria[0], among: criteria, in: unrelated))
        let list = "- \(criteria[0])\n  Tests: \(first.tests.joined(separator: ", "))\n- \(criteria[1])"
        try #require(Self.proofIsAssociatedWithCriterion(first.tests, criterion: criteria[0], among: criteria, in: list))
        let wrongList = "- \(criteria[0])\n- \(criteria[1])\n  Tests: \(first.tests.joined(separator: ", "))"
        try #require(!Self.proofIsAssociatedWithCriterion(first.tests, criterion: criteria[0], among: criteria, in: wrongList))
        let allInOneRow = "| \(criteria.joined(separator: " ")) | \(first.tests.joined(separator: ", ")) |"
        try #require(!Self.proofIsAssociatedWithCriterion(first.tests, criterion: criteria[0], among: criteria, in: allInOneRow))

        let check = fixture.finalEvidence[0]
        let file = URL(fileURLWithPath: check.artifactPath).lastPathComponent
        let row = "| \(check.check) | passed | \(check.commit) | \(check.summary) | \(file) | \(check.artifactSHA256) |"
        try #require(Self.checkIsDescribed(check, among: [check], in: row))
        let wrongResult = row.replacingOccurrences(of: "| passed |", with: "| failed |") + "\n\nOther check passed."
        try #require(!Self.checkIsDescribed(check, among: [check], in: wrongResult))
        let unrelatedFields = "| \(check.check) | passed |\n\n## Unrelated\n\(check.commit) \(check.summary) \(file) \(check.artifactSHA256)"
        try #require(!Self.checkIsDescribed(check, among: [check], in: unrelatedFields))
        let section = """
            ### \(check.check)
            - Result: passed
            - Commit: \(check.commit)
            - Summary: \(check.summary)
            - Evidence: \(file) \(check.artifactSHA256)
            """
        try #require(Self.checkIsDescribed(check, among: [check], in: section))
        let failure = Self.evidence(fixture.root, check: "historical check", passed: false,
                                    summary: "Acceptance failed", details: "CheckoutTests.rejectsMissingAddress")
        let failedRow = "| \(failure.check) | failed | \(failure.commit) | \(failure.summary) | "
            + "\(URL(fileURLWithPath: failure.artifactPath).lastPathComponent) | \(failure.artifactSHA256) | \(failure.details ?? "") |"
        try #require(Self.checkIsDescribed(failure, among: [check, failure], in: row + "\n" + failedRow))
        try #require(!Self.checkIsDescribed(failure, among: [check, failure],
                                           in: row + "\n" + failedRow.replacingOccurrences(of: "| failed |", with: "| passed |")))
    }
}
