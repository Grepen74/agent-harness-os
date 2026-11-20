import Foundation

public enum PullRequestDescription {
    /// GitHub rejects a longer pull request body ("body is too long (maximum is 65536 characters)").
    public static let maximumLength = 65_536
    /// Longer check summaries and details are cut: the full output is in the evidence file.
    static let fieldLimit = 1_000

    /// Describes every check of the breakdown. When that is too long for GitHub, the oldest attempts are left out first,
    /// with a note; the final verification and the latest result of each check always stay.
    public static func render(_ request: RequirementPublicationRequest, root: NodeState,
                       state: WorkingState, closesIssue: Bool, maximumLength: Int = maximumLength) -> String {
        var head = [
            "# \(root.ticket): \(root.spec.title)",
            "Branch: `\(request.branch)`\nCommit: `\(request.commit)`", "## Requirement and breakdown",
        ]
        let nodes = state.subtree(of: root.id)
        for node in nodes {
            head.append("### \(node.ticket): \(node.spec.title)\n\n\(node.spec.intent)")
            for (index, criterion) in node.spec.acceptanceCriteria.enumerated() {
                let tests = request.proofs.filter { $0.node == node.id && $0.criterion == index + 1 }.flatMap(\.tests)
                head.append("- \(criterion)\n  Tests: \(tests.isEmpty ? "No criterion-specific test mapping recorded." : tests.joined(separator: ", "))")
            }
        }
        head.append("## Checks and local evidence\n\nArtifacts remain in local harness storage; nothing is uploaded.")
        var tail: [String] = []
        if closesIssue, root.ticket.hasPrefix("GH-"), let number = Int(root.ticket.dropFirst(3)), number > 0 {
            tail.append("Closes #\(number)")
        }

        let checks = uniqueChecks(nodes.flatMap { node in node.evidence.map { (node.id, $0) } }
            + (request.verification ?? []).map { (root.id, $0) })
        let sections = checks.map { expandedChecks($0.evidence).map(describe).joined(separator: "\n\n") }
        let priority = keptFirst(checks, verification: request.verification ?? [])
        let reserve = omissionNote(checks.count).utf16.count + 2
        var budget = maximumLength - (head + tail).joined(separator: "\n\n").utf16.count - 2 - reserve
        var kept = Set<Int>()
        for index in priority {
            let cost = sections[index].utf16.count + 2
            guard cost <= budget else { continue }
            budget -= cost
            kept.insert(index)
        }
        var body = head + sections.indices.filter(kept.contains).map { sections[$0] }
        if kept.count < sections.count { body.append(omissionNote(sections.count - kept.count)) }
        let text = (body + tail).joined(separator: "\n\n")
        guard text.utf16.count > maximumLength else { return text }
        // Even the breakdown alone is too long: cut it, keeping the closing reference.
        let ending = (["…", omissionNote(sections.count)] + tail).joined(separator: "\n\n")
        return String(decoding: text.utf16.prefix(maximumLength - ending.utf16.count - 2), as: UTF16.self) + "\n\n" + ending
    }

    private static func omissionNote(_ count: Int) -> String {
        "_\(count) earlier check result\(count == 1 ? "" : "s") left out to fit GitHub's limit; " +
            "every result is in the harness ledger._"
    }

    /// The root's final verification is both its evidence and the request's verification: listed once.
    private static func uniqueChecks(_ checks: [(node: NodeID, evidence: Evidence)]) -> [(node: NodeID, evidence: Evidence)] {
        var seen = Set<String>()
        return checks.filter { check in
            seen.insert("\(check.evidence.check)|\(check.evidence.checkedBy)|\(check.evidence.artifactSHA256)").inserted
        }
    }

    /// Final verification first, then the latest result of each check per node, then older ones, newest first.
    private static func keptFirst(_ checks: [(node: NodeID, evidence: Evidence)], verification: [Evidence]) -> [Int] {
        let isVerification = { (evidence: Evidence) in
            verification.contains { $0.checkedBy == evidence.checkedBy && $0.artifactSHA256 == evidence.artifactSHA256 }
        }
        var latest = Set<String>()
        var current: [Int] = [], older: [Int] = []
        for index in checks.indices.reversed() {
            let (node, evidence) = checks[index]
            if latest.insert("\(node)|\(evidence.check)").inserted { current.append(index) } else { older.append(index) }
        }
        let first = checks.indices.filter { isVerification(checks[$0].evidence) }
        return first + (current + older).filter { !first.contains($0) }
    }

    private static func describe(_ check: Evidence) -> String {
        var description = """
            ### \(check.check)
            - Result: \(check.passed ? "passed" : "failed")
            - Commit: \(check.commit)
            - Summary: \(shortened(check.summary))
            - Evidence: \(URL(fileURLWithPath: check.artifactPath).lastPathComponent)
            - SHA-256: \(check.artifactSHA256)
            """
        if !check.passed, let details = check.details {
            description += "\n- Failing tests / details: \(shortened(details))"
        }
        return description
    }

    private static func shortened(_ text: String) -> String {
        text.count <= fieldLimit ? text : text.prefix(fieldLimit) + " … (cut; the full output is in the evidence file)"
    }

    private static func expandedChecks(_ evidence: Evidence) -> [Evidence] {
        [evidence] + (evidence.checks ?? []).map { result in
            var check = evidence
            check.check = result.name
            check.passed = result.passed
            check.summary = result.summary
            check.details = result.failingTests.isEmpty ? nil : result.failingTests.joined(separator: ", ")
            check.checks = nil
            return check
        }
    }
}
