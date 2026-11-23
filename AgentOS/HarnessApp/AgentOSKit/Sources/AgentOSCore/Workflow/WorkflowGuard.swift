/// Conditions are data for inspection and projection; the reconciler remains the controller.
public indirect enum WorkflowGuard: Sendable, Hashable {
    case always
    case predicate(WorkflowPredicate)
    case allOf([WorkflowGuard])
    case anyOf([WorkflowGuard])
    case not(WorkflowGuard)
}

public enum WorkflowPredicate: Sendable, Hashable {
    case signal(HarnessCommand)
    case gateOpen(Gate)
    case flagSet(Flag)
    case fact(WorkflowFact)
}

/// Controller observations, including policy decisions made for the particular node and candidate.
public enum WorkflowFact: String, Sendable, Hashable {
    case ticketReady, breakdownComplete, allChildrenProven, isRoot, rootStepFinished
    case finalVerificationPassed, publishingEnabled, pushSucceeded, pullRequestOpen, mergeDetected
    case catchUpConflicted, mainMergedIntoRequirement
    case testsWritten, testsCompile, reviewRequired, compileFailed, reviewPassed, inputRequired, inputResolved
    case implementationSubmitted, ownChecksPassed, testAuthorFailed, attemptBudgetAvailable
    case brokenTestReported, brokenTestReturnAllowed
    case singleLanding, landingChecksPassed, batchLanding, allMemberReviewsPassed
    case batchChecksFailed, batchFailureAttributable, smallerBatchReady, landed, landingConflicted
    case escalationRequired, diagnoserAvailable, nodeIdle, diagnosisFinished, infrastructureProblem
    case retryAvailable, retryWaitElapsed, isLeaf, notLanded, noBuildingInSubtree
    case previewFinished, catchUpRequired, catchUpFinished, reviewFailed, checksFailed
    case humanReviewRequired, humanReviewApproved
}

public enum WorkflowEffect: String, Sendable, Hashable {
    case openOrUpdateSinglePullRequest, observeMerge, mergeRequirementIntoMain, mergeMainIntoRequirement
    case keepTestDraft, splitBatch, postDiagnosisAdvice, preserveEscalation
    case resetAttempts, discardAcceptanceTests, clearGates
}
