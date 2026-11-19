/// One full check of a combined landing candidate. Member order is landing queue order.
public struct LandingBatchCheck: Codable, Sendable, Equatable {
    public let name: String
    public let branch: String
    public let nodes: [NodeID]
    public let candidateCommit: String
    public let passed: Bool
    public let run: RunID

    public init(name: String, branch: String, nodes: [NodeID], candidateCommit: String, passed: Bool, run: RunID) {
        self.name = name
        self.branch = branch
        self.nodes = nodes
        self.candidateCommit = candidateCommit
        self.passed = passed
        self.run = run
    }
}

extension EventKind {
    public var landingBatchCheck: LandingBatchCheck? {
        guard case .landingBatchChecked(let check) = self else { return nil }
        return check
    }
}
