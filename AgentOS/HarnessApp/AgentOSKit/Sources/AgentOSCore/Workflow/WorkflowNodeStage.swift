/// A node's observable catalog stage. Reviews share their enclosing run's stage until
/// the ledger can distinguish the start of a review from the rest of that run.
public struct WorkflowNodeStage: Sendable, Equatable {
    public let stage: WorkflowStageID
    public let interrupted: Bool

    public init(stage: WorkflowStageID, interrupted: Bool = false) {
        self.stage = stage
        self.interrupted = interrupted
    }
}

extension WorkflowCatalog {
    /// Reads only the replayed state, including the latest claim's durable outcome.
    public func currentStage(of id: NodeID, in state: WorkingState) -> WorkflowNodeStage? {
        guard let node = state.nodes[id] else { return nil }
        if let run = node.latestRun,
           run.outcome == "abandoned" || run.outcome?.hasPrefix("abandoned:") == true {
            return WorkflowNodeStage(stage: Self.stage(of: run), interrupted: true)
        }
        if let run = node.latestRun, node.activeRun?.run == run.run {
            return WorkflowNodeStage(stage: Self.stage(of: run))
        }
        return WorkflowNodeStage(stage: stage(of: node, in: state))
    }

    private static func stage(of run: WorkflowRunState) -> WorkflowStageID {
        switch run.role {
        case .decomposer: .breakdown
        case .testAuthor: .testAuthoring
        case .implementer: .implementation
        case .diagnoser: .diagnosis
        case .verifier:
            if run.isFinalVerification { .finalVerification }
            else if run.phase == .landing { .landing }
            else { .ownChecks }
        }
    }

    private func stage(of node: NodeState, in state: WorkingState) -> WorkflowStageID {
        if node.requirementMerged { return .done }
        if node.catchUpConflict != nil { return .catchUpConflict }
        if node.flags[.escalated] != nil { return .escalated }
        if node.flags[.needsInput] != nil { return .questions }
        if node.openTestProblem != nil && node.phase != .specified { return .brokenTestReport }
        switch node.phase {
        case .specified:
            if node.spec.kind == .leaf { return .testAuthoring }
            return state.hasGate(.breakdown, at: node.id) ? .breakdown : .breakdownGate
        case .split: return .children
        case .ready:
            return state.hasGate(.build, at: node.id) ? .implementation : .buildGate
        case .building: return .implementation
        case .checking: return .ownChecks
        case .landing: return .landing
        case .proven:
            guard node.spec.parent == nil else { return .proven }
            if node.requirementVerificationRetryPending { return .finalVerification }
            if node.requirementVerificationStarted {
                return node.requirementVerification?.passed == true ? .waitingForMerge : .finalVerification
            }
            return .proven
        }
    }
}
