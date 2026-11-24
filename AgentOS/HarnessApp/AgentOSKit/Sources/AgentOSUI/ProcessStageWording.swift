import AgentOSCore

/// Plain wording for catalog stages, shared by Process cards, menus, selection details, the Work
/// stage filter and the selected-node summary. Presentation only: catalog IDs and titles, the
/// ledger and tracker comments keep their own wording.
enum ProcessStageWording {
    static func title(_ stageID: WorkflowStageID) -> String {
        switch stageID {
        case .preview: "Preview the breakdown (creates no tickets)"
        case .breakdownGate: "Allow breakdown"
        case .breakdown: "Create child tickets"
        case .children: "Wait for child work to finish"
        case .proven: "Proven"
        case .finalVerification: "Final check of the requirement branch"
        case .push: "Push the requirement branch"
        case .pullRequest: "Open or update the pull request"
        case .waitingForMerge: "Waiting for merge into main"
        case .done: "Done: merged into main"
        case .catchUp: "Bring in the latest main"
        case .catchUpConflict: "Resolve a conflict with main"
        case .acceptanceTests: "Write acceptance tests"
        case .compileCheck: "Check that the tests compile"
        case .acceptanceTestReview: "Review the acceptance tests"
        case .buildGate: "Allow build"
        case .implementation: "Write the code"
        case .ownChecks: "Run this leaf's tests"
        case .brokenTestReport: "Send a broken test back to its author"
        case .landingQueue: "Wait to land"
        case .landing: "Land the change"
        case .singleLandingChecks: "Run repository checks on the latest branch"
        case .singleChangeReview: "Review the code change"
        case .landingApproval: "Approve landing"
        case .batchMemberReview: "Review each change in the batch"
        case .batchChecks: "Run repository checks on the batch"
        case .batchSplit: "Split a failing batch to find the cause"
        case .landingRework: "Fix a conflict with newer work"
        case .resumeWork: "Resume where it stopped"
        case .infrastructureWait: "Wait, then retry (machine problem)"
        default: WorkflowCatalog.standard.stages.first { $0.id == stageID }?.title ?? stageID
        }
    }

    /// The title outside its lane: "Proven (leaf)" for a per-lane card.
    static func title(_ key: ProcessStageKey) -> String {
        key.kind.map { title(key.stageID) + ($0 == .leaf ? " (leaf)" : " (requirement)") } ?? title(key.stageID)
    }

    /// What happens at a stage, in one or two plain sentences. `kind` narrows a per-lane stage;
    /// `batchSize` is the effective landing batch size, 1 when the policy lands changes one at a time.
    static func description(_ stageID: WorkflowStageID, kind: NodeKind?, batchSize batch: Int) -> String {
        switch stageID {
        case .preview:
            return "An agent drafts the child tickets so you can see the plan. It creates no tickets; "
                + "a person then decides at Allow breakdown."
        case .breakdownGate:
            return "Waits for permission to split the requirement: harness:breakdown, or harness:go, which also "
                + "allows build for everything below. Permission on a requirement above already counts. "
                + "A replanned top-level requirement waits here for a fresh breakdown."
        case .breakdown:
            return "An agent splits the requirement into child tickets, or finds it is small enough to build "
                + "directly."
        case .children:
            return "Each child ticket follows its own workflow: small ones the Leaf lane, bigger ones this lane "
                + "again. This stage waits until every child is proven."
        case .proven where kind == .leaf:
            return "The checked change has landed on the top-level requirement's branch, and the leaf reports "
                + "back to its parent. A small top-level ticket goes on to the final check instead."
        case .proven:
            return "Every child is proven, so all their work is on the top-level requirement's branch. It is not "
                + "merged into main yet: a nested requirement reports back to its parent, a top-level one goes on to "
                + "the final check."
        case .finalVerification:
            return "Top-level requirements only. An agent runs the repository checks once more on the finished "
                + "requirement branch."
        case .push:
            return "Pushes the requirement branch to the remote. Only when publishing is on."
        case .pullRequest:
            return "Opens or updates the requirement's single pull request into main. Only when publishing is on."
        case .waitingForMerge:
            return "Waits for a person to merge the requirement branch into main; the harness never merges it."
        case .done:
            return "The harness saw the requirement merged into main. Nothing more to do."
        case .catchUp:
            return "Main moved on, so the harness merges the latest main into the requirement branch before the "
                + "final check."
        case .catchUpConflict:
            return "Bringing in main hit a conflict. A person merges main into the requirement branch and "
                + "resolves it; there is no retry signal."
        case .acceptanceTests:
            return "An agent writes tests for the leaf's expected behaviour before any code exists. Also where "
                + "tests are rewritten after review findings, a broken-test report or harness:retest."
        case .compileCheck:
            return "The harness compiles the new tests where the repository supports it. Errors about code the "
                + "implementation will add are expected; other compile errors go straight back to the test author."
        case .acceptanceTestReview:
            return "A reviewer checks that the tests match the ticket. Findings go back to the test author."
        case .questions:
            return "An agent reported questions or assumptions that need a person. Answer them, or approve the "
                + "assumptions, to continue."
        case .buildGate:
            return "Waits for permission to write the code: harness:build, or harness:go on this ticket or a "
                + "requirement above it. Assumptions still need approval even under harness:go."
        case .implementation:
            return "An agent writes the code until the acceptance tests pass."
        case .ownChecks:
            return "Runs only this leaf's tests when the repository sets test.only, otherwise the whole test "
                + "command. Extra checks run when it lands."
        case .brokenTestReport:
            return "The implementer found an acceptance test that cannot pass. The harness sends it back to the "
                + "test author, or asks a person when that is not safe."
        case .landingQueue:
            return batch > 1
                ? "Waits its turn to land on the requirement branch, alone or in a batch of up to \(batch)."
                : "Waits its turn to land on the requirement branch, one change at a time."
        case .landing:
            return "Lands the checked change on the requirement branch: repository checks, review and approval "
                + "as configured, then the branch moves forward. Waits while the branch is checked out."
        case .singleLandingChecks:
            return "Puts the change on top of the latest requirement branch and runs the repository checks: "
                + "prepare and build commands, the test command and the extra checks. It fails if this leaf's "
                + "tests, or older tests its test author updated, changed since approval, or if another leaf's "
                + "tests or a protected file changed."
        case .singleChangeReview:
            return "A reviewer checks the code change before it lands. Findings go back to the implementer."
        case .landingApproval:
            return "A person approves landing this exact checked change with harness:build. Changes that need a "
                + "person's review land one at a time."
        case .batchMemberReview:
            return "A reviewer checks each change in the batch on its own before the combined checks."
        case .batchChecks:
            return "Up to \(batch) waiting changes for the same requirement branch are combined and the "
                + "repository checks run once. On failure the harness diagnoses it: it may rerun, remove the "
                + "changes that caused it, split the batch, or ask a person."
        case .batchSplit:
            return "The batch failed and the cause is unclear, so the harness checks smaller parts. A machine "
                + "problem never splits a batch."
        case .landingRework:
            return "The change no longer applies on top of newer work. An agent reworks it, then it is checked "
                + "again."
        case .resumeWork:
            return "Picks the node's workflow up again where it stopped, after a wait or a person's harness:retry."
        case .escalated:
            return "A safety limit or failure needs a person, for example harness:retry or harness:retest. A "
                + "machine problem with retries left goes to Wait, then retry instead."
        case .diagnosis:
            return "An agent looks at the escalated node and posts advice. It does not resume the work or clear "
                + "the escalation."
        case .infrastructureWait:
            return "A machine problem, not the code, stopped the work. The harness waits, then tries again."
        default:
            return ""
        }
    }
}

extension ProcessWorkflow {
    var subtitle: String {
        switch self {
        case .requirement: "Split into child tickets and wait for their work"
        case .leaf: "Tests first, then code, then land"
        case .recovery: "When something goes wrong"
        }
    }
}
