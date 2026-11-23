import AgentOSCore

public enum ProcessSelection: Equatable {
    case stage(String)
    case transition(String)
}

/// A policy-projected catalog with repository occupancy, never persisted to the ledger.
public struct ProcessDiagramPresentation {
    public let stages: [ProcessStagePresentation]
    public let transitions: [ProcessTransitionPresentation]

    init(policy: EffectivePolicy, state: WorkingState) {
        let catalog = WorkflowCatalog.standard
        let projection = WorkflowProjection.project(catalog: catalog, policy: policy, node: nil)
        let occupancy = Dictionary(grouping: state.nodes.keys, by: {
            catalog.currentStage(of: $0, in: state)?.stage ?? ""
        })
        let requirementIDs = Set(catalog.workflows
            .filter { $0.kind == .composite || $0.kind == .rootOnly }.flatMap(\.stages).map(\.id))
        let leafIDs = Set(catalog.workflows.filter { $0.kind == .leaf }.flatMap(\.stages).map(\.id))
        stages = projection.stages.map { stage in
            ProcessStagePresentation(
                stage: stage, nodeIDs: Set(occupancy[stage.id] ?? []),
                workflow: requirementIDs.contains(stage.id) ? .requirement
                    : leafIDs.contains(stage.id) ? .leaf : .recovery)
        }
        transitions = projection.transitions.map { edge in
            ProcessTransitionPresentation(id: "\(edge.from):\(edge.to):\(edge.reason)",
                                          from: edge.from, to: edge.to,
                                          reason: edge.reason, condition: edge.condition)
        }
    }
}

enum ProcessWorkflow: String, CaseIterable {
    case requirement = "Requirement", leaf = "Leaf", recovery = "Recovery"
}

public struct ProcessStagePresentation: Identifiable {
    let stage: WorkflowStage
    let workflow: ProcessWorkflow
    public let nodeIDs: Set<NodeID>
    public var id: String { stage.id }
    public var waitsOnPerson: Bool { stage.actor == .person }
    public var waitingNodeIDs: Set<NodeID> { waitsOnPerson ? nodeIDs : [] }

    init(stage: WorkflowStage, nodeIDs: Set<NodeID>, workflow: ProcessWorkflow) {
        self.stage = stage
        self.nodeIDs = nodeIDs
        self.workflow = workflow
    }

    public var title: String {
        switch id {
        case .breakdownGate: "Breakdown gate"
        case .acceptanceTests: "Acceptance tests"
        case .acceptanceTestReview: "Acceptance-test review"
        case .buildGate: "Build gate"
        case .implementation: "Implementation"
        case .singleChangeReview: "Change review"
        case .landingApproval: "Landing approval"
        case .finalVerification: "Final verification"
        case .push: "Push"
        case .pullRequest: "Pull request"
        default: stage.title
        }
    }

    var actor: String {
        switch stage.actor {
        case .agent(let role): "Agent: \(role.title)"
        case .reviewer: "Reviewer"
        case .person: "Person"
        case .harness: "Harness"
        }
    }

    var nodeCount: String { "\(nodeIDs.count) \(nodeIDs.count == 1 ? "node" : "nodes")" }
    var waitingCount: String { "\(waitingNodeIDs.count) waiting on a person" }
}

public struct ProcessTransitionPresentation: Identifiable {
    public let id: String
    public let from: String
    public let to: String
    public let reason: String
    public let condition: String
}

extension HarnessViewModel {
    public var processDiagram: ProcessDiagramPresentation {
        ProcessDiagramPresentation(
            policy: policy ?? EffectivePolicy.resolve(harness: HarnessSettings(), repo: nil, defaultBranch: nil),
            state: state)
    }
}
