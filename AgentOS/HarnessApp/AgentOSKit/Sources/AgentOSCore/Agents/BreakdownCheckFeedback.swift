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
        case .tooManyCriteria(let child, let title, let count, let limit):
            "Child \(child) \"\(title)\" has \(count) acceptance criteria, more than \(limit): too much for one agent run "
                + "to prove. Split it into smaller children, each with a few related criteria."
        case .repeatedCriterion(let children, let titles, let text):
            "Children \(zip(children, titles).map { "\($0) \"\($1)\"" }.joined(separator: ", ")) all have the criterion "
                + "\"\(text)\": each of their test authors would test it again. Keep it in the child that builds it; the "
                + "others wait for that child (\"after\") and state only what they add, defining its terms in a short clause "
                + "where they need them."
        case .multipleIntegrationChildren(let child, let title):
            "Child \(child) \"\(title)\" is one of multiple integration children. Keep only one integration child; "
                + "remove the extra integration marks."
        case .integrationChildNotLast(let child, let title):
            "Child \(child) \"\(title)\" is an integration child that is not last. Move it to the last position "
                + "or remove its integration mark."
        case .integrationChildWithOneSibling(let child, let title):
            "Child \(child) \"\(title)\" is an integration child with only one other child. Add another ordinary child "
                + "or remove its integration mark."
        case .loneIntegrationChild(let child, let title):
            "Child \(child) \"\(title)\" is a lone integration proposal with no other children. Add at least two ordinary "
                + "children or remove its integration mark to make the parent an ordinary leaf."
        }
    }
}
