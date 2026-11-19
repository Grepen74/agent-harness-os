/// Acceptance-test names associated with one 1-based criterion of a work node.
public struct AcceptanceCriterionProof: Codable, Sendable, Hashable {
    public let node: NodeID
    public let criterion: Int
    public let tests: [String]

    public init(node: NodeID, criterion: Int, tests: [String]) {
        self.node = node
        self.criterion = criterion
        self.tests = tests
    }
}

public struct RequirementPublicationRequest: Sendable {
    public var requirement: NodeID
    public var branch: String
    public var commit: String
    public var verification: [Evidence]?
    public let proofs: [AcceptanceCriterionProof]

    public init(requirement: NodeID, branch: String, commit: String,
                verification: [Evidence]?, proofs: [AcceptanceCriterionProof]) {
        self.requirement = requirement
        self.branch = branch
        self.commit = commit
        self.verification = verification
        self.proofs = proofs
    }
}

