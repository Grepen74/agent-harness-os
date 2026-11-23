import AgentOSCore

public struct ProcessNodeCounters {
    public let failedAttempts: Int
    public let maxAttempts: Int
    public let landingReworks: Int
    public let maxReworks: Int
    public let agentRunsSinceHuman: Int
    public let maxAgentRuns: Int
    public let reviewStage: ReviewStage?
    public let failedReviews: Int
    public let reviewMaxRounds: Int
    public let reviewRoundAllowance: Int
}

public struct ProcessNodeSummary {
    public let nodeID: NodeID
    public let stageID: String
    public let stageTitle: String
    public let status: String
    public let waitReason: String?
    public let interrupted: Bool
    public let reviewLevel: ReviewLevel
    public let counters: ProcessNodeCounters
}

extension HarnessViewModel {
    var processPolicy: EffectivePolicy {
        policy ?? EffectivePolicy.resolve(harness: HarnessSettings(), repo: nil, defaultBranch: nil)
    }

    public var selectedNodeProcess: ProcessNodeSummary? {
        selectedNodeID.flatMap { processSummary(for: $0) }
    }

    public var highlightedProcessStageID: String? { selectedNodeProcess?.stageID }

    public func processSummary(for nodeID: NodeID) -> ProcessNodeSummary? {
        let catalog = WorkflowCatalog.standard
        guard let node = state.nodes[nodeID], let current = catalog.currentStage(of: nodeID, in: state),
              let stage = catalog.stages.first(where: { $0.id == current.stage }) else { return nil }
        let policy = processPolicy.policy
        let reviewStage: ReviewStage? = node.spec.kind != .leaf ? nil
            : node.phase == .specified ? .acceptanceTests : .change
        let failures = reviewStage.map { ReviewBudget.failures(in: records(for: nodeID), stage: $0) } ?? []
        let counters = ProcessNodeCounters(
            failedAttempts: node.failedAttempts, maxAttempts: policy.maxAttempts,
            landingReworks: node.reworks, maxReworks: policy.maxReworks,
            agentRunsSinceHuman: node.agentRunsSinceHuman, maxAgentRuns: policy.maxAgentRuns,
            reviewStage: reviewStage, failedReviews: failures.count, reviewMaxRounds: policy.review.maxRounds,
            reviewRoundAllowance: ReviewBudget.allowance(for: failures, maxRounds: policy.review.maxRounds))
        return ProcessNodeSummary(
            nodeID: nodeID, stageID: current.stage, stageTitle: stage.title, status: state.status(of: node),
            waitReason: processWaitReason(for: node, stage: stage), interrupted: current.interrupted,
            reviewLevel: policy.review.level(for: node.spec.touches + (node.actualChangedFiles ?? [])),
            counters: counters)
    }

    public var matchingWorkNodeIDs: Set<NodeID> {
        guard let stage = workStageFilterID else { return Set(state.nodes.keys) }
        let catalog = WorkflowCatalog.standard
        return Set(state.nodes.keys.filter { catalog.currentStage(of: $0, in: state)?.stage == stage })
    }

    public var visibleWorkNodeIDs: Set<NodeID> {
        var visible = matchingWorkNodeIDs
        for id in matchingWorkNodeIDs {
            var parent = state.nodes[id]?.spec.parent
            var visited: Set<NodeID> = [id]
            while let id = parent, visited.insert(id).inserted, let node = state.nodes[id] {
                visible.insert(id)
                parent = node.spec.parent
            }
        }
        return visible
    }

    public func clearWorkStageFilter() { workStageFilterID = nil }

    private func processWaitReason(for node: NodeState, stage: WorkflowStage) -> String? {
        let reasons = Flag.allCases.compactMap { node.flags[$0] }
        if !reasons.isEmpty { return reasons.joined(separator: "\n") }
        if let message = state.overlapHoldMessage(for: node) { return message }
        if let conflict = node.catchUpConflict {
            return "Merge main into the requirement branch and resolve conflicts in "
                + conflict.files.joined(separator: ", ") + ". There is no retry signal."
        }
        if let failure = node.publicationFailure { return failure }
        if node.awaitingHumanReview {
            return "Review this candidate, then add harness:build to approve it."
        }
        if state.status(of: node) == "Paused" { return "Waiting for the parent requirement's breakdown." }
        if stage.actor == .person {
            let signals = stage.signals.intersection(processPolicy.policy.allowedSignals).map(\.label).sorted()
            return stage.condition + (signals.isEmpty ? "" : " Signals: " + signals.joined(separator: ", "))
        }
        return nil
    }
}
