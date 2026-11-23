extension WorkflowCatalog {
    public static let standard: WorkflowCatalog = {
        let composite = requirementWorkflow(kind: .composite)
        let root = requirementWorkflow(kind: .rootOnly)
        let leaf = leafWorkflow
        // The root leaf also retains planning stages: a breakdown can discover it needs no children.
        let rootLeaf = WorkflowDefinition(
            kind: .rootLeaf, entryStage: leaf.entryStage,
            stages: leaf.stages + root.stages.filter { stage in !leaf.stages.contains { $0.id == stage.id } },
            transitions: leaf.transitions + root.transitions)
        return WorkflowCatalog(workflows: [composite, root, leaf, rootLeaf, recoveryWorkflow],
                               observationTransitions: observableTransitions)
    }()

    private static func requirementWorkflow(kind: WorkflowKind) -> WorkflowDefinition {
        WorkflowDefinition(kind: kind, entryStage: .breakdownGate, stages: [
            .init(id: .preview, title: "Preview breakdown", actor: .agent(.decomposer)),
            .init(id: .breakdownGate, title: "Approve breakdown", actor: .person,
                  phases: [.specified], gate: .breakdown),
            .init(id: .breakdown, title: "Break down requirement", actor: .agent(.decomposer),
                  phases: [.specified]),
            .init(id: .children, title: "Follow child workflows", actor: .harness,
                  phases: [.split], flags: [.blocked],
                  childWorkflows: [.composite: .composite, .leaf: .leaf], childDepthIncrement: 1),
            .init(id: .proven, title: "Proven", actor: .harness, phases: [.proven]),
        ] + rootStages, transitions: [
            .init(.breakdownGate, .preview, "Preview without adopting the ticket",
                  when: [.signal(.preview), .fact(.ticketReady)], actor: .person),
            .init(.preview, .breakdownGate, "Preview finished; a person decides whether to adopt",
                  when: [.fact(.previewFinished)]),
            .init(.breakdownGate, .breakdown, "Approve the breakdown",
                  when: [.signal(.breakdown), .fact(.ticketReady)], actor: .person),
            .init(.breakdownGate, .breakdown, "Approve breakdown and build",
                  when: [.signal(.go), .fact(.ticketReady)], actor: .person),
            .init(.breakdownGate, .breakdown, "Breakdown permission is already open",
                  when: [.gateOpen(.breakdown), .fact(.ticketReady)]),
            .init(.breakdown, .children, "Child tickets are ready to follow their workflows",
                  when: [.fact(.breakdownComplete)]),
            .init(.children, .proven, "Every child is proven", when: [.fact(.allChildrenProven)]),
        ] + rootTransitions)
    }

    private static var rootStages: [WorkflowStage] {
        [
            .init(id: .finalVerification, title: "Final verification on requirement branch",
                  actor: .agent(.verifier), phases: [.proven]),
            .init(id: .push, title: "Push requirement branch", actor: .harness, phases: [.proven]),
            .init(id: .pullRequest, title: "Open or update the single pull request",
                  actor: .harness, phases: [.proven]),
            .init(id: .waitingForMerge, title: "In review: waiting for a person's merge",
                  actor: .person, phases: [.proven]),
            .init(id: .done, title: "Done: merge detected", actor: .harness, phases: [.proven]),
            .init(id: .catchUp, title: "Catch requirement branch up with main", actor: .harness),
            .init(id: .catchUpConflict, title: "Resolve catch-up conflict by merging main into the branch",
                  actor: .person),
        ]
    }

    private static var rootTransitions: [WorkflowTransition] {
        [
            .init(.proven, .finalVerification, "The root's own step has finished",
                  when: [.fact(.isRoot), .fact(.rootStepFinished)]),
            .init(.finalVerification, .push, "Verification passed and publishing is enabled",
                  when: [.fact(.finalVerificationPassed), .fact(.publishingEnabled)]),
            .init(.push, .pullRequest, "Publish the verified branch through one pull request",
                  when: [.fact(.pushSucceeded)], effects: [.openOrUpdateSinglePullRequest]),
            .init(.pullRequest, .waitingForMerge, "The pull request is ready for a person to merge",
                  when: [.fact(.pullRequestOpen)]),
            .init(.finalVerification, .waitingForMerge, "Publishing is off; wait for a manual merge",
                  when: [.fact(.finalVerificationPassed)], unless: [.fact(.publishingEnabled)]),
            .init(.waitingForMerge, .done, "Observe the person's merge into main",
                  when: [.fact(.mergeDetected)], effects: [.observeMerge]),
            .init(.finalVerification, .finalVerification, "A person requests final verification again",
                  when: [.signal(.retry), .fact(.isRoot)], unless: [.fact(.finalVerificationPassed)],
                  actor: .person),
            .init(.push, .push, "A person retries publication without agent rework",
                  when: [.signal(.retry), .fact(.publishingEnabled)], actor: .person),
            .init(.waitingForMerge, .push, "A person requests publication again",
                  when: [.signal(.retry), .fact(.publishingEnabled)], unless: [.fact(.pullRequestOpen)],
                  actor: .person),
            .init(.proven, .catchUp, "Main advanced; catch up before root completion",
                  when: [.fact(.isRoot), .fact(.catchUpRequired)]),
            .init(.catchUp, .catchUpConflict, "Automatic catch-up conflicted; hold the requirement",
                  when: [.fact(.catchUpConflicted)]),
            .init(.catchUpConflict, .catchUp, "A person resolved the conflict by merging main into the branch",
                  when: [.fact(.mainMergedIntoRequirement)], actor: .person,
                  effects: [.mergeMainIntoRequirement]),
            .init(.catchUp, .proven, "Catch-up succeeded; reconsider root verification",
                  when: [.fact(.catchUpFinished), .fact(.rootStepFinished)]),
        ]
    }
}
