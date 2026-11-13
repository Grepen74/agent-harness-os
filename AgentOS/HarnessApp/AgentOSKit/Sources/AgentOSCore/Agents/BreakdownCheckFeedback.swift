/// A checked proposal, kept separately from human clarifications.
public struct BreakdownCheckFeedback: Codable, Sendable {
    public let proposal: [ChildProposal]
    public let findings: [BreakdownFinding]

    public init(proposal: [ChildProposal], findings: [BreakdownFinding]) {
        self.proposal = proposal
        self.findings = findings
    }
}

extension BreakdownFinding {
    public var explanation: String {
        switch self {
        case .vagueReference(let child, let title, let criterion, let text):
            "Child \(child) \"\(title)\", criterion \(criterion): \"\(text)\" is a vague reference; state the rule explicitly."
        case .scopeCriterion(let child, let title, let criterion, let text):
            "Child \(child) \"\(title)\", criterion \(criterion): \"\(text)\" is a path-based scope restriction, not lasting behaviour."
        case .unorderedOverlap(let first, let firstTitle, let second, let secondTitle, let shared):
            "Children \(first) \"\(firstTitle)\" and \(second) \"\(secondTitle)\" overlap without order on: "
                + shared.joined(separator: ", ")
                + ". Ownership wording may explain an acceptable division, but does not suppress this advisory warning."
        }
    }
}
