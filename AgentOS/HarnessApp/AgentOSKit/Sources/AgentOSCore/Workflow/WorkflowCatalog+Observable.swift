extension WorkflowCatalog {
    /// Edges visible at ledger event boundaries, where compile/review and landing substeps
    /// do not yet have their own start events.
    static var observableTransitions: [WorkflowTransition] {
        [
            .init(.testAuthoring, .buildGate, "Acceptance tests and their review finished",
                  when: [.fact(.testsWritten)]),
            .init(.testAuthoring, .implementation, "Acceptance tests finished with build already approved",
                  when: [.fact(.testsWritten), .gateOpen(.build)]),
            .init(.breakdown, .testAuthoring, "The requirement is small enough to be its own leaf",
                  when: [.fact(.isLeaf)]),
            .init(.breakdownGate, .testAuthoring, "A kept preview discovers a root leaf",
                  when: [.fact(.isLeaf)]),
            .init(.ownChecks, .landing, "Own checks passed; queue for landing",
                  when: [.fact(.ownChecksPassed)]),
            .init(.implementation, .landing, "Requeue an unchanged submission whose own checks already passed",
                  when: [.fact(.implementationSubmitted), .fact(.ownChecksPassed)]),
            .init(.landing, .proven, "The checked and reviewed change landed",
                  when: [.fact(.landed)]),
            .init(.landing, .implementation, "Landing needs implementation rework",
                  when: [.fact(.attemptBudgetAvailable)]),
            .init(.landing, .brokenTestReport, "Change review reported a broken acceptance test",
                  when: [.fact(.brokenTestReported)]),
            .init(.landing, .questions, "Landing needs a person's approval or answers",
                  when: [.fact(.inputRequired)]),
            .init(.questions, .landing, "A person approved the landing",
                  when: [.fact(.inputResolved)]),
        ] + observableRecoveryTransitions + observableCatchUpTransitions
    }

    private static var observableRecoveryTransitions: [WorkflowTransition] {
        let resumable: [WorkflowStageID] = [
            .breakdownGate, .breakdown, .children, .testAuthoring, .buildGate,
            .implementation, .ownChecks, .landing, .brokenTestReport, .finalVerification,
        ]
        return resumable.flatMap { stage in [
            .init(stage, .escalated, "A safety limit or failure stops the current stage",
                  when: [.fact(.escalationRequired)]),
            .init(.escalated, stage, "Clearing escalation resumes the node's durable stage",
                  when: [.signal(.retry), .fact(.nodeIdle)], actor: .person),
        ] }
    }

    private static var observableCatchUpTransitions: [WorkflowTransition] {
        let resumable: [WorkflowStageID] = [
            .children, .testAuthoring, .buildGate, .implementation, .ownChecks, .landing,
            .proven, .finalVerification, .push, .pullRequest, .waitingForMerge,
        ]
        return resumable.flatMap { stage in [
            .init(stage, .catchUpConflict, "A recorded catch-up conflict holds the requirement",
                  when: [.fact(.isRoot), .fact(.catchUpConflicted)]),
            .init(.catchUpConflict, stage, "A person's merge resolves the hold; resume recorded work",
                  when: [.fact(.isRoot), .fact(.mainMergedIntoRequirement)], actor: .person),
        ] }
    }
}
