/// Payload-independent event cases used by ledger filters.
public enum LedgerEventKind: String, Hashable, CaseIterable, Sendable {
    case signalAccepted, signalRejected, previewRecorded, previewStarted, previewFinished, breakdownChecked, breakdownRetryRequested
    case nodeCreated, linkAdded, becameLeaf, replanned, breakdownRevised
    case gateOpened, phaseChanged, flagSet, flagCleared, attemptsReset
    case overlapHoldStarted, overlapHoldEnded
    case testsFixed, otherTestsUpdated, reviewRecorded, humanReviewRequested, humanReviewApproved
    case expectedAPIReported, brokenTestReported, brokenTestRouted, runStarted, agentConfigured, runFinished
    case changeSubmitted, attemptFailed, testDraftKept, diagnosisRecorded, acceptanceTestPreflightFailed, passingCheckRecorded, mainMovedRework
    case evidenceRecorded, landingReworkNeeded, landingRerunRequested, reworkNeeded, landed
    case questionsRaised, assumptionsReported, suggestionsReported, questionsAnswered, externalDependencyResolved
    case ticketClosed, ticketReopened, readinessScanned, baselineChecked
    case catchUpConflicted, catchUpSucceeded, caughtUp

    public init(_ kind: EventKind) {
        switch kind {
        case .signalAccepted: self = .signalAccepted
        case .signalRejected: self = .signalRejected
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
        case .testsFixed: self = .testsFixed
        case .otherTestsUpdated: self = .otherTestsUpdated
        case .reviewRecorded: self = .reviewRecorded
        case .humanReviewRequested: self = .humanReviewRequested
        case .humanReviewApproved: self = .humanReviewApproved
        case .expectedAPIReported: self = .expectedAPIReported
        case .brokenTestReported: self = .brokenTestReported
        case .brokenTestRouted: self = .brokenTestRouted
        case .runStarted: self = .runStarted
        case .agentConfigured: self = .agentConfigured
        case .runFinished: self = .runFinished
        case .changeSubmitted: self = .changeSubmitted
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
        case .questionsRaised: self = .questionsRaised
        case .assumptionsReported: self = .assumptionsReported
        case .suggestionsReported: self = .suggestionsReported
        case .questionsAnswered: self = .questionsAnswered
        case .externalDependencyResolved: self = .externalDependencyResolved
        case .ticketClosed: self = .ticketClosed
        case .ticketReopened: self = .ticketReopened
        case .readinessScanned: self = .readinessScanned
        case .baselineChecked: self = .baselineChecked
        case .catchUpConflicted: self = .catchUpConflicted
        case .catchUpSucceeded: self = .catchUpSucceeded
        case .caughtUp: self = .caughtUp
        }
    }
}
