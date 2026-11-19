import Foundation

public enum PullRequestDescription {
    public static func render(_ request: RequirementPublicationRequest, root: NodeState,
                       state: WorkingState, closesIssue: Bool) -> String {
        var sections = [
            "# \(root.ticket): \(root.spec.title)", root.spec.intent,
            "Branch: `\(request.branch)`\nCommit: `\(request.commit)`", "## Requirement and breakdown",
        ]
        let nodes = state.subtree(of: root.id)
        for node in nodes {
            sections.append("### \(node.ticket): \(node.spec.title)\n\n\(node.spec.intent)")
            for (index, criterion) in node.spec.acceptanceCriteria.enumerated() {
                let tests = request.proofs.filter { $0.node == node.id && $0.criterion == index + 1 }.flatMap(\.tests)
                sections.append("- \(criterion)\n  Tests: \(tests.isEmpty ? "No criterion-specific test mapping recorded." : tests.joined(separator: ", "))")
            }
        }
        sections.append("## Checks and local evidence\n\nArtifacts remain in local harness storage; nothing is uploaded.")
        let checks = nodes.flatMap(\.evidence) + (request.verification ?? [])
        for check in checks.flatMap(expandedChecks) {
            var description = """
                ### \(check.check)
                - Result: \(check.passed ? "passed" : "failed")
                - Commit: \(check.commit)
                - Summary: \(check.summary)
                - Evidence: \(URL(fileURLWithPath: check.artifactPath).lastPathComponent)
                - SHA-256: \(check.artifactSHA256)
                """
            if !check.passed, let details = check.details {
                description += "\n- Failing tests / details: \(details)"
            }
            sections.append(description)
        }
        if closesIssue, root.ticket.hasPrefix("GH-"), let number = Int(root.ticket.dropFirst(3)), number > 0 {
            sections.append("Closes #\(number)")
        }
        return sections.joined(separator: "\n\n")
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
