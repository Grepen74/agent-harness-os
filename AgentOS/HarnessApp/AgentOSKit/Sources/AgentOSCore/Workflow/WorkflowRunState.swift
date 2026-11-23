/// The latest claim and its outcome, retained independently of recovery phase changes.
public struct WorkflowRunState: Sendable {
    public let run: RunID
    public let role: AgentRole
    public let phase: Phase
    public let isFinalVerification: Bool
    public internal(set) var outcome: String?
}
