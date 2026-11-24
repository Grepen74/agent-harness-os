import Foundation

/// Describes controller behavior, not executable permissions or ledger state.
public struct WorkflowCatalog: Sendable, Equatable {
    public var workflows: [WorkflowDefinition] {
        didSet {
            stages = Self.flattenedStages(workflows)
            transitions = Self.flattenedTransitions(workflows) + observationTransitions
        }
    }
    /// The editable logical graph. Workflow definitions retain single/batch scope detail.
    public var stages: [WorkflowStage]
    public var transitions: [WorkflowTransition]
    /// Ledger-level edges spanning substeps that have no separate start event. These
    /// validate replay, but must not bypass gates in the detailed policy projection.
    public let observationTransitions: [WorkflowTransition]

    public init(workflows: [WorkflowDefinition], observationTransitions: [WorkflowTransition] = []) {
        self.workflows = workflows
        self.observationTransitions = observationTransitions
        self.stages = Self.flattenedStages(workflows)
        self.transitions = Self.flattenedTransitions(workflows) + observationTransitions
    }
}

public enum WorkflowKind: String, Sendable, Hashable {
    case composite, rootOnly, leaf, rootLeaf, recovery
}

public struct WorkflowDefinition: Sendable, Equatable {
    public var kind: WorkflowKind
    public var entryStage: WorkflowStageID
    public var stages: [WorkflowStage]
    public var transitions: [WorkflowTransition]

    public init(kind: WorkflowKind, entryStage: WorkflowStageID,
                stages: [WorkflowStage], transitions: [WorkflowTransition]) {
        self.kind = kind
        self.entryStage = entryStage
        self.stages = stages
        self.transitions = transitions
    }
}

/// String identifiers also allow callers to supply their own catalog stages.
public typealias WorkflowStageID = String

public enum WorkflowActor: Sendable, Hashable {
    case agent(AgentRole)
    case reviewer, person, harness
}

public enum WorkflowScope: Sendable, Hashable {
    case requirementBranch, eachBatchMember, combinedBatch
}

/// Policy references; values remain in the effective policy rather than copied into the catalog.
public enum WorkflowLimit: Sendable, Hashable {
    case maxAttempts, reviewMaxRounds, convergingReviewMaxRounds(multiplier: Int), maxReworks, maxAgentRuns
}

public enum WorkflowRetrySchedule: Sendable, Hashable {
    case infrastructureRetryDelays
}

public struct WorkflowStage: Sendable, Equatable {
    public var id: WorkflowStageID
    public var title: String
    public var actor: WorkflowActor
    public var phases: Set<Phase>
    public var flags: Set<Flag>
    public var gate: Gate?
    public var scope: WorkflowScope
    public var childWorkflows: [NodeKind: WorkflowKind]
    public var childDepthIncrement: Int
    public var limits: Set<WorkflowLimit>
    public var retrySchedule: WorkflowRetrySchedule?
    public var signals: Set<HarnessCommand>
    public var condition: String
    public var settings: [String: String]

    public init(id: WorkflowStageID, title: String, actor: WorkflowActor,
                phases: Set<Phase> = [], flags: Set<Flag> = [], gate: Gate? = nil,
                scope: WorkflowScope = .requirementBranch,
                childWorkflows: [NodeKind: WorkflowKind] = [:], childDepthIncrement: Int = 0,
                limits: Set<WorkflowLimit> = [], retrySchedule: WorkflowRetrySchedule? = nil,
                signals: Set<HarnessCommand> = [], condition: String = "",
                settings: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.actor = actor
        self.phases = phases
        self.flags = flags
        self.gate = gate
        self.scope = scope
        self.childWorkflows = childWorkflows
        self.childDepthIncrement = childDepthIncrement
        self.limits = limits
        self.retrySchedule = retrySchedule
        self.signals = signals
        self.condition = condition
        self.settings = settings
    }

    public func retryDelays(in policy: Policy) -> [TimeInterval] {
        switch retrySchedule {
        case .infrastructureRetryDelays: policy.infrastructureRetryDelays
        case nil: []
        }
    }
}

public struct WorkflowTransition: Sendable, Equatable {
    public var source: String { from }
    public var target: String { to }
    public var signals: Set<HarnessCommand> { guardCondition.openingSignals }
    public var condition: String { guardCondition.description }
    public var from: WorkflowStageID
    public var to: WorkflowStageID
    public var reason: String
    public var guardCondition: WorkflowGuard
    public var actor: WorkflowActor
    public var effects: Set<WorkflowEffect>

    public init(from: WorkflowStageID, to: WorkflowStageID, reason: String,
                guardCondition: WorkflowGuard, actor: WorkflowActor = .harness,
                effects: Set<WorkflowEffect> = []) {
        self.from = from
        self.to = to
        self.reason = reason
        self.guardCondition = guardCondition
        self.actor = actor
        self.effects = effects
    }

    init(_ from: WorkflowStageID, _ to: WorkflowStageID, _ reason: String,
         when predicates: [WorkflowPredicate], unless forbidden: [WorkflowPredicate] = [],
         actor: WorkflowActor = .harness, effects: Set<WorkflowEffect> = []) {
        self.init(from: from, to: to, reason: reason,
                  guardCondition: .allOf(predicates.map(WorkflowGuard.predicate)
                    + forbidden.map { .not(.predicate($0)) }),
                  actor: actor, effects: effects)
    }
}
