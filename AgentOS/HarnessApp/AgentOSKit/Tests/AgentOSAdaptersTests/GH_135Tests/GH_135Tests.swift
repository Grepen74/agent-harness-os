// API contract: AgentOSCore.WorkflowCatalog.standard exposes five WorkflowDefinitions as data.
// Stages have stable IDs, actors, phase/flag/gate annotations, scopes, child workflow references
// and policy limit references. Transitions have endpoints, reasons, typed Boolean guards, actors
// and observable effects. Root-leaf and composite definitions include applicable root-only edges.
// WorkflowStage.retryDelays(in:) resolves an infrastructureRetryDelays schedule from Policy.
// Criterion 6's CaseIterable declarations/access levels are reviewed in the diff; their exhaustive
// behavior and compatibility with pre-catalog ledger event JSON are tested here. No UI/projection
// or replay-to-stage API is required by this item.

import AgentOSCore
import Foundation
import Testing

@Suite struct GH_135Tests {
    @Test
    func everyWorkflowHasNamedActorsAndReasonedGuardedTransitionsWithValidEndpoints() throws {
        let catalog = WorkflowCatalog.standard
        for kind in [WorkflowKind.composite, .rootOnly, .leaf, .rootLeaf, .recovery] {
            let workflow = try Self.workflow(kind)
            #expect(!workflow.stages.isEmpty, "A workflow must describe its stages")
            #expect(!workflow.transitions.isEmpty, "A workflow must describe its transitions")
            let ids = Set(workflow.stages.map(\.id))
            #expect(ids.count == workflow.stages.count, "Stage IDs are unique within a workflow")
            #expect(ids.contains(workflow.entryStage))
            for stage in workflow.stages {
                #expect(!stage.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            for edge in workflow.transitions {
                #expect(ids.contains(edge.from), "Missing source of \(edge.from) -> \(edge.to)")
                #expect(ids.contains(edge.to), "Missing destination of \(edge.from) -> \(edge.to)")
                #expect(!edge.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(!Self.predicates(edge.guardCondition).isEmpty,
                        "Transitions describe a real condition, not an unconditional arrow")
            }
        }
        let actors = Set(catalog.workflows.flatMap { $0.stages.map(\.actor) })
        #expect(actors.contains(.reviewer))
        #expect(actors.contains(.person))
        #expect(actors.contains(.harness))
        for role in AgentRole.allCases {
            #expect(actors.contains(.agent(role)), "No stage says \(role) acts")
        }
    }

    @Test
    func everyCorePhaseFlagGateSignalAndAgentRoleAppearsInActualCatalogData() throws {
        let catalog = WorkflowCatalog.standard
        try #require(!catalog.workflows.isEmpty)
        let stages = catalog.workflows.flatMap(\.stages)
        let conditions = Set(catalog.workflows.flatMap(\.transitions)
            .flatMap { Self.predicates($0.guardCondition) })
        for phase in Phase.allCases {
            #expect(stages.contains { $0.phases.contains(phase) }, "Uncatalogued phase: \(phase)")
        }
        for flag in Flag.allCases {
            #expect(stages.contains { $0.flags.contains(flag) } || conditions.contains(.flagSet(flag)),
                    "Uncatalogued flag: \(flag)")
        }
        for gate in Gate.allCases {
            #expect(stages.contains { $0.gate == gate }, "No stage represents gate \(gate)")
            #expect(conditions.contains(.gateOpen(gate)), "No transition uses gate \(gate)")
        }
        for signal in HarnessCommand.allCases {
            #expect(conditions.contains(.signal(signal)), "No transition represents \(signal.label)")
        }
        for role in AgentRole.allCases {
            #expect(stages.contains { $0.actor == .agent(role) }, "Uncatalogued agent: \(role)")
        }
        #expect(stages.contains { $0.actor == .reviewer }, "The reviewer is not an AgentRole")
    }

    @Test
    func compositePreviewAndHumanBreakdownGateLeadToRecursiveChildren() throws {
        for kind in [WorkflowKind.composite, .rootOnly] {
            let flow = try Self.workflow(kind)
            #expect(try Self.stage(.preview, in: flow).actor == .agent(.decomposer))
            #expect(try Self.stage(.breakdownGate, in: flow).actor == .person)
            #expect(try Self.stage(.breakdownGate, in: flow).gate == .breakdown)
            #expect(try Self.stage(.breakdown, in: flow).actor == .agent(.decomposer))
            try Self.edge(flow, .breakdownGate, .preview, when: [.signal(.preview), .fact(.ticketReady)],
                          without: [.signal(.preview)])
            for signal in [HarnessCommand.breakdown, .go] {
                let facts: Set<WorkflowPredicate> = [.signal(signal), .fact(.ticketReady)]
                try Self.edge(flow, .breakdownGate, .breakdown, when: facts,
                              without: [.signal(signal)], actor: .person)
            }
            try Self.edge(flow, .breakdown, .children, when: [.fact(.breakdownComplete)])
            let children = try Self.stage(.children, in: flow)
            #expect(children.childWorkflows[.composite] == .composite)
            #expect(children.childWorkflows[.leaf] == .leaf)
            #expect(children.childDepthIncrement == 1, "Nested composites repeat at the child level")
            try Self.edge(flow, .children, .proven, when: [.fact(.allChildrenProven)],
                          without: [.fact(.allChildrenProven)])
        }
    }

    @Test
    func rootVerificationPublishesOnePullRequestOnlyWhenEnabledAndWaitsForDetectedHumanMerge() throws {
        for kind in [WorkflowKind.composite, .rootOnly, .rootLeaf] {
            let flow = try Self.workflow(kind)
            try Self.edge(flow, .proven, .finalVerification,
                          when: [.fact(.isRoot), .fact(.rootStepFinished)],
                          without: [.fact(.isRoot), .fact(.rootStepFinished)])
            let verification = try Self.stage(.finalVerification, in: flow)
            #expect(verification.actor == .agent(.verifier))
            #expect(verification.scope == .requirementBranch)
            #expect(try Self.stage(.push, in: flow).actor == .harness)
            #expect(try Self.stage(.pullRequest, in: flow).actor == .harness)
            #expect(try Self.stage(.waitingForMerge, in: flow).actor == .person)
            let ready: Set<WorkflowPredicate> = [.fact(.finalVerificationPassed), .fact(.publishingEnabled)]
            try Self.edge(flow, .finalVerification, .push, when: ready,
                          without: [.fact(.publishingEnabled), .fact(.finalVerificationPassed)])
            try Self.edge(flow, .push, .pullRequest, when: [.fact(.pushSucceeded)],
                          effects: [.openOrUpdateSinglePullRequest])
            try Self.edge(flow, .pullRequest, .waitingForMerge, when: [.fact(.pullRequestOpen)])
            try Self.edge(flow, .finalVerification, .waitingForMerge,
                          when: [.fact(.finalVerificationPassed)],
                          without: [.fact(.finalVerificationPassed)],
                          addingForbidden: [.fact(.publishingEnabled)])
            try Self.edge(flow, .waitingForMerge, .done, when: [.fact(.mergeDetected)],
                          without: [.fact(.mergeDetected)], actor: .harness, effects: [.observeMerge])
            for transition in flow.transitions where
                !transition.effects.isDisjoint(with: [.mergeRequirementIntoMain, .mergeMainIntoRequirement]) {
                #expect(transition.actor == .person, "The harness must never merge into main")
            }
        }
        #expect(!WorkflowCatalog.standard.workflows.flatMap(\.transitions).contains {
            $0.actor == .harness
                && !$0.effects.isDisjoint(with: [.mergeRequirementIntoMain, .mergeMainIntoRequirement])
        }, "No workflow may assign a merge effect to the harness")
    }

    @Test
    func catchUpConflictWaitsForAPersonToMergeMainAndNoHarnessCommandReleasesIt() throws {
        for kind in [WorkflowKind.composite, .rootOnly, .rootLeaf] {
            let flow = try Self.workflow(kind)
            #expect(try Self.stage(.catchUp, in: flow).actor == .harness)
            #expect(try Self.stage(.catchUpConflict, in: flow).actor == .person)
            try Self.edge(flow, .catchUp, .catchUpConflict, when: [.fact(.catchUpConflicted)])
            try Self.edge(flow, .catchUpConflict, .catchUp,
                          when: [.fact(.mainMergedIntoRequirement)],
                          without: [.fact(.mainMergedIntoRequirement)], actor: .person)
            let exits = flow.transitions.filter { $0.from == .catchUpConflict && $0.to != .catchUpConflict }
            try #require(!exits.isEmpty)
            for exit in exits {
                #expect(exit.actor == .person, "A person resolves the catch-up conflict")
                #expect(!Self.predicates(exit.guardCondition).contains {
                    if case .signal = $0 { return true }
                    return false
                }, "No retry or other signal leaves the conflict hold")
                for signal in HarnessCommand.allCases {
                    #expect(!Self.satisfied(exit.guardCondition, by: [.signal(signal)]))
                }
            }
        }
    }

    @Test
    func leafAuthorsTestsCompilesThenReviewsBeforeItsConditionalInputStopAndBuildGate() throws {
        let flow = try Self.workflow(.leaf)
        #expect(flow.entryStage == .acceptanceTests)
        #expect(try Self.stage(.acceptanceTests, in: flow).actor == .agent(.testAuthor))
        #expect(try Self.stage(.compileCheck, in: flow).actor == .harness)
        #expect(try Self.stage(.acceptanceTestReview, in: flow).actor == .reviewer)
        #expect(try Self.stage(.questions, in: flow).actor == .person)
        #expect(try Self.stage(.buildGate, in: flow).actor == .person)
        #expect(try Self.stage(.buildGate, in: flow).gate == .build)
        try Self.edge(flow, .acceptanceTests, .compileCheck, when: [.fact(.testsWritten)])
        try Self.edge(flow, .compileCheck, .acceptanceTestReview,
                      when: [.fact(.testsCompile), .fact(.reviewRequired)],
                      without: [.fact(.testsCompile)])
        try Self.edge(flow, .compileCheck, .acceptanceTests, when: [.fact(.compileFailed)])
        try Self.edge(flow, .acceptanceTestReview, .questions,
                      when: [.fact(.reviewPassed), .fact(.inputRequired)],
                      without: [.fact(.inputRequired)])
        try Self.edge(flow, .acceptanceTestReview, .buildGate, when: [.fact(.reviewPassed)],
                      addingForbidden: [.fact(.inputRequired)])
        try Self.edge(flow, .questions, .buildGate, when: [.fact(.inputResolved)],
                      without: [.fact(.inputResolved)])
        for signal in [HarnessCommand.build, .go] {
            try Self.edge(flow, .buildGate, .implementation, when: [.signal(signal)],
                          without: [.signal(signal)], actor: .person)
        }
        try Self.edge(flow, .buildGate, .implementation, when: [.gateOpen(.build)])
        #expect(try Self.stage(.implementation, in: flow).actor == .agent(.implementer))
        #expect(try Self.stage(.ownChecks, in: flow).actor == .agent(.verifier))
        try Self.edge(flow, .implementation, .ownChecks, when: [.fact(.implementationSubmitted)])
        try Self.edge(flow, .ownChecks, .landingQueue, when: [.fact(.ownChecksPassed)],
                      without: [.fact(.ownChecksPassed)])
    }

    @Test
    func failedTestAuthoringKeepsItsDraftAndBrokenTestsReturnToTheTestAuthor() throws {
        let flow = try Self.workflow(.leaf)
        try Self.edge(flow, .acceptanceTests, .acceptanceTests,
                      when: [.fact(.testAuthorFailed), .fact(.attemptBudgetAvailable)],
                      without: [.fact(.testAuthorFailed)], effects: [.keepTestDraft])
        #expect(try Self.stage(.brokenTestReport, in: flow).actor == .harness)
        try Self.edge(flow, .implementation, .brokenTestReport, when: [.fact(.brokenTestReported)])
        try Self.edge(flow, .brokenTestReport, .acceptanceTests,
                      when: [.fact(.brokenTestReturnAllowed)],
                      without: [.fact(.brokenTestReturnAllowed)])
    }

    @Test
    func singleLandingChecksBeforeChangeReviewWhileBatchesReviewMembersBeforeCombinedChecks() throws {
        let flow = try Self.workflow(.leaf)
        #expect(try Self.stage(.singleLandingChecks, in: flow).actor == .agent(.verifier))
        #expect(try Self.stage(.singleChangeReview, in: flow).actor == .reviewer)
        let memberReview = try Self.stage(.batchMemberReview, in: flow)
        #expect(memberReview.actor == .reviewer)
        #expect(memberReview.scope == .eachBatchMember)
        let combinedCheck = try Self.stage(.batchChecks, in: flow)
        #expect(combinedCheck.actor == .agent(.verifier))
        #expect(combinedCheck.scope == .combinedBatch)
        try Self.edge(flow, .landingQueue, .singleLandingChecks, when: [.fact(.singleLanding)],
                      without: [.fact(.singleLanding)])
        try Self.edge(flow, .singleLandingChecks, .singleChangeReview,
                      when: [.fact(.landingChecksPassed), .fact(.reviewRequired)],
                      without: [.fact(.landingChecksPassed)])
        try Self.edge(flow, .landingQueue, .batchMemberReview,
                      when: [.fact(.batchLanding), .fact(.reviewRequired)],
                      without: [.fact(.batchLanding)])
        try Self.edge(flow, .batchMemberReview, .batchChecks,
                      when: [.fact(.allMemberReviewsPassed)], without: [.fact(.allMemberReviewsPassed)])
        try Self.edge(flow, .batchChecks, .batchSplit,
                      when: [.fact(.batchChecksFailed), .fact(.batchFailureAttributable)],
                      without: [.fact(.batchChecksFailed), .fact(.batchFailureAttributable)],
                      effects: [.splitBatch])
        #expect(try Self.stage(.batchSplit, in: flow).actor == .harness)
        try Self.edge(flow, .batchSplit, .batchChecks, when: [.fact(.smallerBatchReady)])
        try Self.edge(flow, .singleChangeReview, .proven,
                      when: [.fact(.reviewPassed), .fact(.landed)])
        try Self.edge(flow, .batchChecks, .proven,
                      when: [.fact(.landingChecksPassed), .fact(.landed)])
    }

    @Test
    func landingConflictsReworkTheImplementationThenReturnToLanding() throws {
        let flow = try Self.workflow(.leaf)
        #expect(try Self.stage(.landingRework, in: flow).actor == .agent(.implementer))
        for source in [WorkflowStageID.singleLandingChecks, .batchMemberReview, .batchChecks] {
            try Self.edge(flow, source, .landingRework, when: [.fact(.landingConflicted)])
        }
        try Self.edge(flow, .landingRework, .ownChecks, when: [.fact(.implementationSubmitted)])
        try Self.edge(flow, .ownChecks, .landingQueue, when: [.fact(.ownChecksPassed)])
        #expect(try Self.stage(.proven, in: flow).phases.contains(.proven))
    }

    @Test
    func aRootLeafIncludesTheLeafFlowThenTheGuardedRootCompletionFlow() throws {
        let leaf = try Self.workflow(.leaf)
        let root = try Self.workflow(.rootOnly)
        let rootLeaf = try Self.workflow(.rootLeaf)
        #expect(rootLeaf.entryStage == leaf.entryStage)
        for source in [leaf, root] {
            for stage in source.stages {
                let composed = try Self.stage(stage.id, in: rootLeaf)
                #expect(composed.actor == stage.actor)
                #expect(composed.limits.isSuperset(of: stage.limits))
            }
            for edge in source.transitions {
                #expect(rootLeaf.transitions.contains {
                    $0.from == edge.from && $0.to == edge.to
                        && $0.guardCondition == edge.guardCondition && $0.effects.isSuperset(of: edge.effects)
                }, "A root leaf retains guarded \(edge.from) -> \(edge.to)")
            }
        }
        try Self.edge(rootLeaf, .proven, .finalVerification,
                      when: [.fact(.isRoot), .fact(.rootStepFinished)],
                      without: [.fact(.rootStepFinished)])
    }

    @Test
    func diagnosisPostsAdviceButReturnsToEscalatedForAPerson() throws {
        let flow = try Self.workflow(.recovery)
        let escalated = try Self.stage(.escalated, in: flow)
        #expect(escalated.actor == .person)
        #expect(escalated.flags.contains(.escalated))
        try Self.edge(flow, .resumeWork, .escalated, when: [.fact(.escalationRequired)],
                      without: [.fact(.escalationRequired)], actor: .harness)
        #expect(try Self.stage(.diagnosis, in: flow).actor == .agent(.diagnoser))
        try Self.edge(flow, .escalated, .diagnosis,
                      when: [.flagSet(.escalated), .fact(.diagnoserAvailable), .fact(.nodeIdle)],
                      without: [.flagSet(.escalated)])
        try Self.edge(flow, .diagnosis, .escalated, when: [.fact(.diagnosisFinished)],
                      effects: [.postDiagnosisAdvice, .preserveEscalation])
        for exit in flow.transitions where exit.from == .diagnosis {
            #expect(exit.to == .escalated, "Diagnosis never resumes the work or clears its escalation")
        }
    }

    @Test
    func infrastructureRecoveryUsesEveryConfiguredWaitAndRequiresAnEligibleProblemAndRemainingRetry() throws {
        let flow = try Self.workflow(.recovery)
        let wait = try Self.stage(.infrastructureWait, in: flow)
        #expect(wait.actor == .harness)
        #expect(wait.retrySchedule == .infrastructureRetryDelays)
        var policy = Policy()
        policy.infrastructureRetryDelays = [7, 31, 89, 233]
        #expect(wait.retryDelays(in: policy) == policy.infrastructureRetryDelays)
        policy.infrastructureRetryDelays = []
        #expect(wait.retryDelays(in: policy).isEmpty)
        try Self.edge(flow, .escalated, .infrastructureWait,
                      when: [.flagSet(.escalated), .fact(.infrastructureProblem), .fact(.retryAvailable)],
                      without: [.fact(.infrastructureProblem), .fact(.retryAvailable)])
        try Self.edge(flow, .infrastructureWait, .resumeWork,
                      when: [.fact(.retryWaitElapsed), .fact(.retryAvailable), .fact(.nodeIdle)],
                      without: [.fact(.retryWaitElapsed), .fact(.retryAvailable), .fact(.nodeIdle)])
    }

    @Test
    func retryRetestAndReplanHaveHumanTransitionsAndTheirOwnSafetyGuards() throws {
        let flow = try Self.workflow(.recovery)
        try Self.edge(flow, .escalated, .resumeWork,
                      when: [.signal(.retry), .flagSet(.escalated), .fact(.nodeIdle)],
                      without: [.signal(.retry), .flagSet(.escalated), .fact(.nodeIdle)],
                      actor: .person, effects: [.resetAttempts])
        for flag in [Flag.escalated, .needsInput] {
            let facts: Set<WorkflowPredicate> = [
                .signal(.retest), .flagSet(flag), .fact(.isLeaf), .fact(.notLanded), .fact(.nodeIdle),
            ]
            try Self.edge(flow, flag == .escalated ? .escalated : .questions, .acceptanceTests,
                          when: facts,
                          without: [.signal(.retest), .flagSet(flag), .fact(.isLeaf), .fact(.notLanded), .fact(.nodeIdle)],
                          actor: .person, effects: [.discardAcceptanceTests])
        }
        let updateTest: Set<WorkflowPredicate> = [
            .signal(.updateTest), .flagSet(.needsInput), .fact(.brokenTestReported), .fact(.isLeaf),
            .fact(.notLanded), .fact(.nodeIdle),
        ]
        try Self.edge(flow, .questions, .acceptanceTests, when: updateTest,
                      without: [.signal(.updateTest), .flagSet(.needsInput), .fact(.brokenTestReported),
                                .fact(.notLanded), .fact(.nodeIdle)],
                      addingForbidden: [.fact(.brokenTestReturnAllowed)], actor: .person)
        let replan: Set<WorkflowPredicate> = [
            .signal(.replan), .fact(.isRoot), .fact(.noBuildingInSubtree), .fact(.nodeIdle), .fact(.ticketReady),
        ]
        try Self.edge(flow, .resumeWork, .breakdownGate, when: replan,
                      without: [.signal(.replan), .fact(.isRoot), .fact(.noBuildingInSubtree),
                                .fact(.nodeIdle), .fact(.ticketReady)],
                      actor: .person, effects: [.clearGates])
    }

    @Test
    func boundedStagesNameAttemptsReviewRoundsConvergingAllowanceReworksAndAgentRunBudgets() throws {
        let flow = try Self.workflow(.leaf)
        for id in [WorkflowStageID.acceptanceTests, .implementation] {
            #expect(try Self.stage(id, in: flow).limits.contains(.maxAgentRuns))
        }
        for id in [WorkflowStageID.acceptanceTests, .ownChecks, .singleLandingChecks, .batchChecks] {
            #expect(try Self.stage(id, in: flow).limits.contains(.maxAttempts))
        }
        for id in [WorkflowStageID.acceptanceTestReview, .singleChangeReview, .batchMemberReview] {
            let stage = try Self.stage(id, in: flow)
            #expect(stage.limits.contains(.reviewMaxRounds))
            #expect(stage.limits.contains(.convergingReviewMaxRounds(multiplier: 2)))
        }
        #expect(try Self.stage(.landingRework, in: flow).limits.contains(.maxReworks))
    }

    @Test
    func catalogBuildGuardsRequireBuildGoOrAnAlreadyOpenedBuildGate() throws {
        let permissions: Set<WorkflowPredicate> = [.signal(.build), .signal(.go), .gateOpen(.build)]
        let predicates = Set(WorkflowCatalog.standard.workflows.flatMap(\.transitions)
            .flatMap { Self.predicates($0.guardCondition) })
            .union(HarnessCommand.allCases.map { WorkflowPredicate.signal($0) })
            .union(Gate.allCases.map { WorkflowPredicate.gateOpen($0) })
            .union(Flag.allCases.map { WorkflowPredicate.flagSet($0) })
        for kind in [WorkflowKind.leaf, .rootLeaf] {
            let flow = try Self.workflow(kind)
            let transitions = flow.transitions.filter { $0.from == .buildGate && $0.to == .implementation }
            try #require(!transitions.isEmpty, "\(kind) needs a guarded build transition")
            #expect(!transitions.contains { Self.satisfied($0.guardCondition, by: []) })
            for predicate in predicates {
                #expect(transitions.contains { Self.satisfied($0.guardCondition, by: [predicate]) }
                        == permissions.contains(predicate),
                        "\(kind) build permission must not come from \(predicate)")
            }
            #expect(!transitions.contains {
                Self.satisfied($0.guardCondition, by: predicates.subtracting(permissions))
            }, "Other catalog facts cannot replace build permission")
        }
    }

    private static func workflow(_ kind: WorkflowKind) throws -> WorkflowDefinition {
        try #require(WorkflowCatalog.standard.workflows.first { $0.kind == kind },
                     "The catalog is missing the \(kind) workflow")
    }

    private static func stage(_ id: WorkflowStageID, in flow: WorkflowDefinition) throws -> WorkflowStage {
        try #require(flow.stages.first { $0.id == id }, "\(flow.kind) is missing stage \(id)")
    }

    private static func predicates(_ guardCondition: WorkflowGuard) -> [WorkflowPredicate] {
        switch guardCondition {
        case .always: []
        case .predicate(let value): [value]
        case .allOf(let parts), .anyOf(let parts): parts.flatMap(Self.predicates)
        case .not(let part): Self.predicates(part)
        }
    }

    private static func satisfied(_ guardCondition: WorkflowGuard, by facts: Set<WorkflowPredicate>) -> Bool {
        switch guardCondition {
        case .always: true
        case .predicate(let value): facts.contains(value)
        case .allOf(let parts): parts.allSatisfy { Self.satisfied($0, by: facts) }
        case .anyOf(let parts): parts.contains { Self.satisfied($0, by: facts) }
        case .not(let part): !Self.satisfied(part, by: facts)
        }
    }

    private static func edge(
        _ flow: WorkflowDefinition, _ from: WorkflowStageID, _ to: WorkflowStageID,
        when facts: Set<WorkflowPredicate>, without required: [WorkflowPredicate] = [],
        addingForbidden forbidden: Set<WorkflowPredicate> = [], actor: WorkflowActor? = nil,
        effects: Set<WorkflowEffect> = []
    ) throws {
        let edges = flow.transitions.filter { $0.from == from && $0.to == to }
        let enabled = edges.filter { Self.satisfied($0.guardCondition, by: facts) }
        try #require(!enabled.isEmpty, "\(flow.kind) needs a guarded \(from) -> \(to) for \(facts)")
        #expect(enabled.contains { $0.effects.isSuperset(of: effects) })
        if let actor { #expect(enabled.allSatisfy { $0.actor == actor }) }
        for condition in required {
            #expect(!edges.contains { Self.satisfied($0.guardCondition, by: facts.subtracting([condition])) },
                    "\(from) -> \(to) must not proceed without \(condition)")
        }
        for condition in forbidden {
            #expect(!edges.contains { Self.satisfied($0.guardCondition, by: facts.union([condition])) },
                    "\(from) -> \(to) must not proceed with \(condition)")
        }
    }
}
