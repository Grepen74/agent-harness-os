/// Payload-independent event cases used by ledger filters.
public enum LedgerEventKind: String, Hashable, CaseIterable, Sendable {
    case signalAccepted, signalRejected, previewRecorded, previewStarted, previewFinished, breakdownChecked, breakdownRetryRequested
    case commentIgnored
    case ticketDescriptionObserved
    case nodeCreated, linkAdded, becameLeaf, replanned, breakdownRevised
    case gateOpened, phaseChanged, flagSet, flagCleared, attemptsReset
    case overlapHoldStarted, overlapHoldEnded
    case testsRecorded, testsFixed, testUpdatesApproved, otherTestsUpdated, reviewRecorded, humanReviewRequested, humanReviewApproved
    case requirementBranchCreated
    case requirementBranchObserved, requirementCatchUpConflicted
    case requirementBranchContainmentObserved
    case requirementVerificationStarted, requirementVerificationFinished, requirementVerificationRetryRequested, requirementMerged
    case requirementPushed, requirementPullRequestOpened, requirementPublicationFinished
    case requirementVerificationStatusPosted, requirementVerificationStatusPostFailed
    case requirementPullRequestMerged, requirementPullRequestClosed, requirementPullRequestReopened
    case requirementPublicationStarted
    case requirementPublicationFailed, requirementPublicationRetryRequested, acceptanceCriterionProofsRecorded
    case expectedAPIReported, brokenTestReported, brokenTestRouted, runStarted, agentConfigured, runFinished
    case agentCreditsRecorded
    case runConfigurationRecorded
    case runCostRecorded
    case changeSubmitted, attemptFailed, testDraftKept, diagnosisRecorded, acceptanceTestPreflightFailed, passingCheckRecorded, mainMovedRework
    case actualChangedFilesRecorded, predictedPathsExpanded
    case evidenceRecorded, landingReworkNeeded, landingRerunRequested, reworkNeeded, landed
    case landingBatchChecked, landingBatchMemberRemoved
    case landingBatchSplit, landingBatchOwnersRemoved
    case questionsRaised, assumptionsReported, suggestionsReported, questionsAnswered, externalDependencyResolved
    case ticketClosed, ticketReopened, readinessScanned, baselineChecked
    case mainFetchWarningChanged, safeStopChanged, ledgerCutBack
    case catchUpConflicted, catchUpSucceeded, caughtUp

    public init(_ kind: EventKind) {
        switch kind {
        case .signalAccepted: self = .signalAccepted
        case .signalRejected: self = .signalRejected
        case .commentIgnored: self = .commentIgnored
        case .ticketDescriptionObserved: self = .ticketDescriptionObserved
        case .previewRecorded: self = .previewRecorded
        case .previewStarted: self = .previewStarted
        case .previewFinished: self = .previewFinished
        case .breakdownChecked: self = .breakdownChecked
        case .breakdownRetryRequested: self = .breakdownRetryRequested
        case .nodeCreated: self = .nodeCreated
        case .linkAdded: self = .linkAdded
        case .becameLeaf: self = .becameLeaf
        case .replanned: self = .replanned
        case .breakdownRevised: self = .breakdownRevised
        case .gateOpened: self = .gateOpened
        case .phaseChanged: self = .phaseChanged
        case .flagSet: self = .flagSet
        case .flagCleared: self = .flagCleared
        case .attemptsReset: self = .attemptsReset
        case .overlapHoldStarted: self = .overlapHoldStarted
        case .overlapHoldEnded: self = .overlapHoldEnded
        case .testsRecorded: self = .testsRecorded
        case .testsFixed: self = .testsFixed
        case .testUpdatesApproved: self = .testUpdatesApproved
        case .requirementBranchCreated: self = .requirementBranchCreated
        case .requirementBranchObserved: self = .requirementBranchObserved
        case .requirementBranchContainmentObserved: self = .requirementBranchContainmentObserved
        case .requirementCatchUpConflicted: self = .requirementCatchUpConflicted
        case .requirementVerificationStarted: self = .requirementVerificationStarted
        case .requirementVerificationFinished: self = .requirementVerificationFinished
        case .requirementVerificationRetryRequested: self = .requirementVerificationRetryRequested
        case .requirementMerged: self = .requirementMerged
        case .requirementPushed: self = .requirementPushed
        case .requirementVerificationStatusPosted: self = .requirementVerificationStatusPosted
        case .requirementVerificationStatusPostFailed: self = .requirementVerificationStatusPostFailed
        case .requirementPublicationStarted: self = .requirementPublicationStarted
        case .requirementPullRequestOpened: self = .requirementPullRequestOpened
        case .requirementPullRequestMerged: self = .requirementPullRequestMerged
        case .requirementPullRequestClosed: self = .requirementPullRequestClosed
        case .requirementPullRequestReopened: self = .requirementPullRequestReopened
        case .requirementPublicationFinished: self = .requirementPublicationFinished
        case .requirementPublicationFailed: self = .requirementPublicationFailed
        case .requirementPublicationRetryRequested: self = .requirementPublicationRetryRequested
        case .acceptanceCriterionProofsRecorded: self = .acceptanceCriterionProofsRecorded
        case .otherTestsUpdated: self = .otherTestsUpdated
        case .reviewRecorded: self = .reviewRecorded
        case .humanReviewRequested: self = .humanReviewRequested
        case .humanReviewApproved: self = .humanReviewApproved
        case .expectedAPIReported: self = .expectedAPIReported
        case .brokenTestReported: self = .brokenTestReported
        case .brokenTestRouted: self = .brokenTestRouted
        case .runStarted: self = .runStarted
        case .agentConfigured: self = .agentConfigured
        case .runConfigurationRecorded: self = .runConfigurationRecorded
        case .agentCreditsRecorded: self = .agentCreditsRecorded
        case .runCostRecorded: self = .runCostRecorded
        case .runFinished: self = .runFinished
        case .changeSubmitted: self = .changeSubmitted
        case .actualChangedFilesRecorded: self = .actualChangedFilesRecorded
        case .predictedPathsExpanded: self = .predictedPathsExpanded
        case .attemptFailed: self = .attemptFailed
        case .testDraftKept: self = .testDraftKept
        case .diagnosisRecorded: self = .diagnosisRecorded
        case .acceptanceTestPreflightFailed: self = .acceptanceTestPreflightFailed
        case .passingCheckRecorded: self = .passingCheckRecorded
        case .mainMovedRework: self = .mainMovedRework
        case .evidenceRecorded: self = .evidenceRecorded
        case .landingReworkNeeded: self = .landingReworkNeeded
        case .landingRerunRequested: self = .landingRerunRequested
        case .reworkNeeded: self = .reworkNeeded
        case .landed: self = .landed
        case .landingBatchChecked: self = .landingBatchChecked
        case .landingBatchMemberRemoved: self = .landingBatchMemberRemoved
        case .landingBatchSplit: self = .landingBatchSplit
        case .landingBatchOwnersRemoved: self = .landingBatchOwnersRemoved
        case .questionsRaised: self = .questionsRaised
        case .assumptionsReported: self = .assumptionsReported
        case .suggestionsReported: self = .suggestionsReported
        case .questionsAnswered: self = .questionsAnswered
        case .externalDependencyResolved: self = .externalDependencyResolved
        case .ticketClosed: self = .ticketClosed
        case .ticketReopened: self = .ticketReopened
        case .readinessScanned: self = .readinessScanned
        case .baselineChecked: self = .baselineChecked
        case .mainFetchWarningChanged: self = .mainFetchWarningChanged
        case .safeStopChanged: self = .safeStopChanged
        case .ledgerCutBack: self = .ledgerCutBack
        case .catchUpConflicted: self = .catchUpConflicted
        case .catchUpSucceeded: self = .catchUpSucceeded
        case .caughtUp: self = .caughtUp
        }
    }
}
