/// A read-only view of the supplied catalog, specialized without changing the controller or ledger.
public struct WorkflowProjection: Sendable, Equatable {
    public var stages: [WorkflowStage]
    public var transitions: [WorkflowTransition]

    public static func project(
        catalog: WorkflowCatalog, policy: EffectivePolicy, node: NodeState?
    ) -> WorkflowProjection {
        let context = ProjectionContext(policy: policy.policy, node: node)
        let stages = catalog.stages.filter { context.includes($0, catalog: catalog) }
        let ids = Set(stages.map(\.id))
        let transitions = catalog.transitions.compactMap { edge -> WorkflowTransition? in
            guard !catalog.observationTransitions.contains(edge) else { return nil }
            guard ids.contains(edge.source), ids.contains(edge.target) else { return nil }
            var result = edge
            result.guardCondition = edge.guardCondition.specializing(context.resolve)
            return result.guardCondition.isImpossible ? nil : result
        }
        return WorkflowProjection(stages: stages.map { stage in
            var result = context.annotate(stage)
            result.signals.formUnion(transitions.filter { $0.source == stage.id }.flatMap(\.signals))
            result.signals.formIntersection(policy.policy.allowedSignals)
            return result
        }, transitions: transitions)
    }
}

private struct ProjectionContext {
    let policy: Policy
    let node: NodeState?
    let review: ReviewLevel
    let areaRules: [String: ReviewLevel]
    let inputRequired: Bool?
    let assumptionApprovalRequired: Bool?

    init(policy: Policy, node: NodeState?) {
        self.policy = policy
        self.node = node
        let evidence = node.map { $0.spec.touches + ($0.actualChangedFiles ?? []) }
        areaRules = evidence.map { policy.review.matchingAreaRules(for: $0) } ?? policy.review.areas
        review = evidence.map { policy.review.level(for: $0) }
            ?? policy.review.areas.values.reduce(policy.review.level, max)
        inputRequired = node.map {
            let report = AgentReport(questions: $0.openQuestions, assumptions: $0.allAssumptions)
            return !policy.questions(in: report, role: $0.spec.kind == .leaf ? .testAuthor : .decomposer).isEmpty
        }
        assumptionApprovalRequired = node.map {
            policy.guesswork == .assumeAndReport && !$0.allAssumptions.isEmpty
        }
    }

    private var batchAllowed: Bool {
        policy.landingBatchSize > 1
            && (node == nil ? policy.review.level : review) != .agentAndHuman
    }

    func resolve(_ predicate: WorkflowPredicate) -> Bool? {
        switch predicate {
        case .signal(let command):
            // An enabled signal is still a person's action, never an automatic permission.
            return policy.allowedSignals.contains(command) ? nil : false
        case .gateOpen(let gate):
            return node.map { $0.gates.contains(gate) }
        case .flagSet: return nil
        case .fact(let fact):
            switch fact {
            case .publishingEnabled: return policy.pullRequests
            case .reviewRequired:
                if node != nil { return review != .none }
                if policy.review.level != .none { return true }
                return review == .none ? false : nil
            case .humanReviewRequired:
                if node != nil { return review == .agentAndHuman }
                if policy.review.level == .agentAndHuman { return true }
                return review == .agentAndHuman ? nil : false
            case .batchLanding: return batchAllowed ? nil : false
            case .singleLanding: return batchAllowed ? nil : true
            case .inputRequired: return inputRequired
            case .assumptionApprovalRequired:
                return policy.guesswork == .assumeAndReport ? assumptionApprovalRequired : false
            case .isRoot: return node.map { $0.spec.parent == nil }
            case .isLeaf: return node.map { $0.spec.kind == .leaf }
            default: return nil
            }
        }
    }

    func includes(_ stage: WorkflowStage, catalog: WorkflowCatalog) -> Bool {
        if let node {
            if node.spec.parent != nil && Self.rootStages.contains(stage.id) { return false }
            let leaf = Set(catalog.workflows.filter { $0.kind == .leaf }
                .flatMap(\.stages).map { WorkflowCatalog.logicalID($0.id) })
            let composite = Set(catalog.workflows.filter { $0.kind == .composite }
                .flatMap(\.stages).map { WorkflowCatalog.logicalID($0.id) }).subtracting(Self.rootStages)
            if node.spec.kind == .leaf {
                if composite.subtracting(leaf).contains(stage.id) { return false }
            } else if leaf.subtracting(composite).subtracting([.questions]).contains(stage.id) {
                return false
            }
        }
        switch stage.id {
        case .acceptanceTestReview, .singleChangeReview, .batchMemberReview:
            return review != .none
        case .landingApproval: return review == .agentAndHuman
        case .batchChecks, .batchSplit: return batchAllowed
        case .push, .pullRequest: return policy.pullRequests
        case .questions: return inputRequired != false
        case .buildGate:
            return node?.gates.contains(.build) != true
                || assumptionApprovalRequired == true || inputRequired == true
        default: return true
        }
    }

    func annotate(_ stage: WorkflowStage) -> WorkflowStage {
        var result = stage
        var explanations = [stage.condition].filter { !$0.isEmpty }
        if [.acceptanceTestReview, .singleChangeReview, .batchMemberReview,
            .landingApproval, .landingQueue, .batchChecks, .singleLandingChecks].contains(stage.id) {
            result.settings["review.level"] = policy.review.level.rawValue
            for (area, level) in areaRules {
                result.settings["review.areas.\(area)"] = level.rawValue
            }
            let areas = areaRules.filter { $0.value != .none }.sorted { $0.key < $1.key }
                .map { "\($0.key) (\($0.value.rawValue))" }
            explanations.append("review.level = \(policy.review.level.rawValue)")
            if !areas.isEmpty { explanations.append("Review areas: \(areas.joined(separator: ", "))") }
            if node != nil { explanations.append("Effective node review: \(review.rawValue)") }
        }
        if [.acceptanceTests, .questions, .buildGate, .implementation].contains(stage.id) {
            result.settings["agents.guesswork"] = policy.guesswork.rawValue
        }
        if stage.id == .questions {
            explanations.append(policy.guesswork == .ask
                ? "Stop when the run reports questions or assumptions"
                : "Stop when the run reports unresolved questions")
        }
        if stage.id == .buildGate {
            explanations.append("A person approves with harness:build")
            if assumptionApprovalRequired == true {
                result.signals.remove(.go)
                explanations.append("Assumptions require approval even under harness:go")
            }
        }
        if Self.rootStages.contains(stage.id) {
            result.settings["pullRequests"] = String(policy.pullRequests)
        }
        for limit in stage.limits {
            switch limit {
            case .maxAttempts: result.settings["limits.maxAttempts"] = String(policy.maxAttempts)
            case .maxReworks: result.settings["limits.maxReworks"] = String(policy.maxReworks)
            case .maxAgentRuns: result.settings["limits.maxAgentRuns"] = String(policy.maxAgentRuns)
            case .reviewMaxRounds: result.settings["review.maxRounds"] = String(policy.review.maxRounds)
            case .convergingReviewMaxRounds(let multiplier):
                result.settings["review.convergingMaxRounds"] = String(policy.review.maxRounds * multiplier)
            }
        }
        if [.landingQueue, .batchChecks, .batchSplit].contains(stage.id) {
            result.settings["limits.landingBatchSize"] = String(policy.landingBatchSize)
        }
        result.condition = explanations.joined(separator: "; ")
        return result
    }

    private static let rootStages: Set<String> = [
        .finalVerification, .push, .pullRequest, .waitingForMerge, .done, .catchUp, .catchUpConflict,
    ]
}
