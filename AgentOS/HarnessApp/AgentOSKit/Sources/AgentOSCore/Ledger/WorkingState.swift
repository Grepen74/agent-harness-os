import Foundation

public struct ActiveRun: Sendable, Hashable {
    public let run: RunID
    public let role: AgentRole
    public let since: Date
}

public struct Submission: Sendable, Hashable {
    public let run: RunID
    public let commit: String
}

public struct SuggestedAnswers: Sendable {
    public let questions: [AgentQuestion]
    public let reportedAt: Date
}

public struct Preview: Sendable, Hashable {
    public let number: Int
    public let specHash: String
    public let proposal: [NodeSpec]
    public var breakdownWarnings: [BreakdownFinding] = []
    /// When it was recorded: answers given later weren't used by it.
    public var recordedAt: Date?
}

/// A preview whose decomposer is running now. Not a node's run: the ticket may not be adopted.
public struct RunningPreview: Sendable, Equatable, Identifiable {
    public var id: RunID { run }
    public let ticket: String
    /// The ID the ticket's node would get; it names the run's log.
    public let node: NodeID
    public let run: RunID
    public let since: Date
    /// The model and reasoning effort, when the team knows them; the latest fallback once it fell back.
    public var settings: AgentRunSettings?
}

public struct CatchUpConflict: Sendable, Hashable {
    public let mainSHA: String
    public let files: [String]
    public let tickets: [String]

    public init(mainSHA: String, files: [String], tickets: [String]) {
        self.mainSHA = mainSHA
        self.files = files
        self.tickets = tickets
    }
}

public struct CatchUpSuccess: Sendable, Hashable {
    public let mainSHA: String
    public let newAgentOSMainTip: String
    public let method: CatchUpMethod

    public init(mainSHA: String, newAgentOSMainTip: String, method: CatchUpMethod) {
        self.mainSHA = mainSHA
        self.newAgentOSMainTip = newAgentOSMainTip
        self.method = method
    }
}

public struct RequirementBranchObservation: Sendable, Equatable {
    public let tip: String
    public let main: String
    public let containedInMain: Bool
}

/// The current state of one Work Node, derived from its events.
public struct NodeState: Sendable, Identifiable {
    public var id: NodeID { spec.id }
    public var identity: NodeIdentity { NodeIdentity(ticketKey: ticket, nodeID: id) }
    public var displayName: String { identity.displayName }
    public var spec: NodeSpec
    public var ticket: String
    /// Position of the last event that touched this node; used for compare-and-swap.
    public var version: Int
    public var phase: Phase = .specified
    public var overlapHold: OverlapHold?
    public var flags: [Flag: String] = [:]
    /// A person closed the ticket: no more work, and its flags don't ask for attention.
    public var ticketClosed = false
    public var gates: Set<Gate> = []
    public var links: [TypedLink] = []
    public var children: [NodeID] = []
    public var testsDigest: String?
    public var requirementBranch: String?
    public var requirementBranchObservation: RequirementBranchObservation?
    public var requirementVerificationStarted = false
    public var requirementVerification: Evidence?
    public var requirementVerificationRetryPending = false
    public var requirementMerged = false
    public var pullRequestNumber: Int?
    public var pullRequestURL: String?
    public var pullRequestState: RequirementPullRequest.State?
    public var publishedCommit: String?
    public var publicationFailure: String?
    public var publicationRetryPending = false
    public var acceptanceCriterionProofs: [AcceptanceCriterionProof] = []
    public var catchUpConflict: CatchUpConflict?
    public var lastCatchUpSuccess: CatchUpSuccess?
    /// Other work's tests this node's acceptance tests changed, locked by `updatedOtherTestsDigest`.
    public var updatedOtherTests: [String] = []
    public var updatedOtherTestsDigest: String?
    public var expectedAPI: [String] = []
    public var brokenTestReports: [BrokenTestReport] = []
    /// The newest problem with this node's acceptance tests (broken-test report or failed compile), for the test author.
    public var latestTestFeedback: String?
    /// A problem reported with the current acceptance tests (broken-test report or failed compile), for the
    /// implementer. Tests fixed again replace them, so whatever was said about the earlier ones no longer applies.
    public var openTestProblem: String?
    /// The claim: at most one agent run per node at a time.
    public var activeRun: ActiveRun?
    public fileprivate(set) var recordedAICredits: Double = 0
    fileprivate var startedAgentRuns: Set<RunID> = []
    fileprivate var runsWithRecordedCost: Set<RunID> = []
    /// Includes unfinished agent runs, but not the harness's non-agent verifier runs.
    public var runsWithoutRecordedCost: Int {
        startedAgentRuns.subtracting(runsWithRecordedCost).count
    }
    public var lastSubmission: Submission?
    /// The submitted branch diff; nil until submission or after a reset, and [] for a known empty diff.
    public var actualChangedFiles: [String]?
    public var evidence: [Evidence] = []
    public var reviews: [ReviewRecord] = []
    public var latestReviewFeedback: String?
    /// A person answered since the latest change review, so the implementer may now leave its findings unaddressed.
    public var reviewFeedbackAnswered = false
    public var pendingHumanReview: String?
    public var approvedReviewCommit: String?
    public var awaitingHumanReview: Bool { pendingHumanReview != nil }
    public var failedAttempts = 0
    public var recentFailures: [String] = []
    /// Files of a failed test-author run's kept draft, for the next test-author run to continue from.
    public var testDraft: [String]?
    /// Escalated since the diagnoser last looked (cleared with the escalation).
    public var needsDiagnosis = false
    /// Test-author and implementer runs since a person last acted on the node: the ticket's run budget.
    public var agentRunsSinceHuman = 0
    public var landingReworkPending = false
    public var landingRerunPending = false
    public var reworks = 0
    /// Position in the landing queue (when it entered `landing`).
    public var queuedAt: Int?
    public var landedCommit: String?
    /// Ledger position of the latest landing: a requirement branch's later landings contain its earlier ones.
    public var landedAt: Int?
    /// What an agent asked and nobody answered yet (with the `needsInput` flag).
    public var openQuestions: [AgentQuestion] = []
    /// Choices agents made themselves, per role (the decomposer's for a breakdown, the test author's for tests).
    public var assumptions: [AgentRole: [String]] = [:]
    public var suggestedAnswers: [AgentRole: SuggestedAnswers] = [:]
    /// Answers people gave on this node's ticket.
    public var clarifications: [Clarification] = []

    /// Every assumption on this node, decomposer first.
    public var allAssumptions: [String] {
        [AgentRole.decomposer, .testAuthor, .implementer, .verifier, .diagnoser].flatMap { assumptions[$0] ?? [] }
    }
}

/// The small, current part of the ledger that the reconciler reads (doc 04 §6).
/// It is never stored on its own: it can always be rebuilt by replaying the events.
/// Production: kept as indexed database tables next to the event log.
public struct WorkingState: Sendable {
    public private(set) var asOf = -1
    public private(set) var nodes: [NodeID: NodeState] = [:]
    public private(set) var creationOrder: [NodeID] = []
    /// Latest preview per ticket.
    public private(set) var previews: [String: Preview] = [:]
    /// Previews running now, by ticket.
    public private(set) var runningPreviews: [String: RunningPreview] = [:]
    private var pendingBreakdownWarnings: [String: [BreakdownFinding]] = [:]
    public private(set) var resolvedExternal: Set<String> = []
    /// The latest recorded readiness scan of the repo.
    public private(set) var readiness: ReadinessScan?
    /// The latest baseline run on the default branch.
    public private(set) var baseline: Baseline?
    public private(set) var catchUpConflict: CatchUpConflict?
    public private(set) var lastCatchUpSuccess: CatchUpSuccess?

    /// Tickets of nodes discarded by a replan, with the ticket that was replanned.
    public private(set) var superseded: [String: String] = [:]

    public init() {}

    public var roots: [NodeState] {
        creationOrder.compactMap { nodes[$0] }.filter { $0.spec.parent == nil }
    }

    /// Leaves waiting to land, first come first served.
    public var landingQueue: [NodeState] {
        nodes.values.filter { $0.phase == .landing && $0.flags[.escalated] == nil && $0.activeRun == nil && !$0.ticketClosed }
            .sorted { ($0.queuedAt ?? 0) < ($1.queuedAt ?? 0) }
    }

    /// Nodes with an agent or check running right now, oldest run first.
    public var running: [NodeState] {
        nodes.values.filter { $0.activeRun != nil }.sorted { $0.activeRun!.since < $1.activeRun!.since }
    }

    public func node(forTicket key: String) -> NodeState? {
        nodes.values.first { $0.ticket == key }
    }

    /// Gates are inherited: a gate on a parent covers everything below it.
    public func hasGate(_ gate: Gate, at id: NodeID) -> Bool {
        var current: NodeID? = id
        while let nodeID = current, let node = nodes[nodeID] {
            if node.gates.contains(gate) { return true }
            current = node.spec.parent
        }
        return false
    }

    /// Everything that needs a human right now (doc 06): the most important view.
    public var attentionList: [(node: NodeState, flag: Flag, reason: String)] {
        creationOrder.compactMap { nodes[$0] }.filter { !$0.ticketClosed }.flatMap { node in
            var items = Flag.allCases.compactMap { flag in node.flags[flag].map { (node, flag, $0) } }
            if let conflict = node.catchUpConflict {
                items.append((node, .needsInput,
                              "\(node.requirementBranch ?? node.ticket) catch-up needs a person: \(conflict.files.joined(separator: ", "))"))
            }
            if node.requirementVerificationStarted && node.requirementVerification?.passed != true && !node.requirementMerged
                && node.activeRun == nil {
                items.append((node, .needsInput,
                              "Final verification needs a person: \(node.requirementVerification?.summary ?? "interrupted"). Fix the problem, then add harness:retry."))
            }
            if let failure = node.publicationFailure {
                items.append((node, .needsInput, failure))
            }
            return items
        }
    }

    /// The node and its parents, the node first.
    public func lineage(of id: NodeID) -> [NodeState] {
        var result: [NodeState] = []
        var current: NodeID? = id
        while let nodeID = current, let node = nodes[nodeID] {
            result.append(node)
            current = node.spec.parent
        }
        return result
    }

    public func requirementLeaves(for id: NodeID) -> [NodeState] {
        creationOrder.compactMap { nodes[$0] }.filter {
            $0.spec.kind == .leaf && lineage(of: $0.id).last?.id == id
        }
    }

    /// Answers given on the node's ticket and its parents', oldest (topmost) first: they apply below too.
    public func clarifications(for id: NodeID) -> [Clarification] {
        lineage(of: id).reversed().flatMap(\.clarifications)
    }

    /// Assumptions this node's work rests on: its own and its parents', topmost first.
    public func assumptions(for id: NodeID) -> [String] {
        lineage(of: id).reversed().flatMap(\.allAssumptions)
    }

    /// The node and everything below it.
    public func subtree(of id: NodeID) -> [NodeState] {
        guard let node = nodes[id] else { return [] }
        return [node] + node.children.flatMap { subtree(of: $0) }
    }

    mutating func apply(_ record: RecordedEvent) {
        asOf = record.position
        let event = record.event

        if case .nodeCreated(let spec, let ticket) = event.kind {
            nodes[spec.id] = NodeState(spec: spec, ticket: ticket, version: record.position)
            creationOrder.append(spec.id)
            if let parent = spec.parent { nodes[parent]?.children.append(spec.id) }
            return
        }

        if case .replanned(let spec) = event.kind, let id = event.node, let old = nodes[id] {
            previews[old.ticket] = nil
            // Kept: the answers people gave on the ticket, and the children until the next breakdown decides.
            var node = NodeState(spec: spec, ticket: old.ticket, version: record.position)
            node.clarifications = old.clarifications
            node.children = old.children
            node.overlapHold = old.overlapHold
            node.requirementBranch = old.requirementBranch
            node.requirementBranchObservation = old.requirementBranchObservation
            node.catchUpConflict = old.catchUpConflict
            node.lastCatchUpSuccess = old.lastCatchUpSuccess
            node.pullRequestNumber = old.pullRequestNumber
            node.pullRequestURL = old.pullRequestURL
            node.pullRequestState = old.pullRequestState
            node.publishedCommit = old.publishedCommit
            node.recordedAICredits = old.recordedAICredits
            node.startedAgentRuns = old.startedAgentRuns
            node.runsWithRecordedCost = old.runsWithRecordedCost
            nodes[id] = node
            return
        }

        if case .breakdownRevised(let kept, let dropped) = event.kind, let id = event.node, let parent = nodes[id] {
            for gone in dropped {
                if let ticket = nodes[gone]?.ticket { superseded[ticket] = parent.ticket }
                nodes[gone] = nil
            }
            creationOrder.removeAll { dropped.contains($0) }
            nodes[id]?.children.removeAll { dropped.contains($0) }
            nodes[id]?.version = record.position
            for spec in kept {
                guard var child = nodes[spec.id] else { continue }
                child.spec = spec
                child.links = spec.dependsOn.map { TypedLink(from: spec.id, type: .dependsOn, to: $0) }
                child.version = record.position
                nodes[spec.id] = child
            }
            return
        }

        switch event.kind {
        case .breakdownChecked(let ticket, let check):
            pendingBreakdownWarnings[ticket] = check.findings
        case .previewRecorded(let ticket, let number, let specHash, let proposal):
            previews[ticket] = Preview(number: number, specHash: specHash, proposal: proposal,
                                      breakdownWarnings: pendingBreakdownWarnings.removeValue(forKey: ticket) ?? [],
                                      recordedAt: event.at)
        case .previewStarted(let ticket, let node, let run):
            runningPreviews[ticket] = RunningPreview(ticket: ticket, node: node, run: run, since: event.at)
        case .previewFinished(let ticket, let run, _):
            if runningPreviews[ticket]?.run == run { runningPreviews[ticket] = nil }
        case .agentConfigured(let run, let settings) where event.node == nil:
            if let ticket = runningPreviews.first(where: { $0.value.run == run })?.key {
                runningPreviews[ticket]?.settings = settings
            }
        case .externalDependencyResolved(let ref):
            resolvedExternal.insert(ref)
        case .readinessScanned(let scan):
            readiness = scan
        case .baselineChecked(let result):
            baseline = result
        case .catchUpConflicted(let main, let files, let tickets):
            catchUpConflict = CatchUpConflict(mainSHA: main, files: files, tickets: tickets)
        case .catchUpSucceeded(let main, let tip, let method):
            catchUpConflict = nil
            lastCatchUpSuccess = CatchUpSuccess(mainSHA: main, newAgentOSMainTip: tip, method: method)
        default:
            break
        }

        guard let id = event.node, var node = nodes[id] else { return }
        node.version = record.position
        if event.by.isHuman { node.agentRunsSinceHuman = 0 }

        switch event.kind {
        case .linkAdded(let link): node.links.append(link)
        case .becameLeaf(let touches, let predictedPaths):
            node.spec.kind = .leaf
            node.spec.touches = touches
            node.spec.predictedPaths = predictedPaths ?? []
        case .gateOpened(let gate): node.gates.insert(gate)
        case .phaseChanged(let phase):
            node.phase = phase
            node.queuedAt = phase == .landing ? record.position : nil
        case .flagSet(let flag, let reason):
            if flag == .escalated, node.flags[.escalated] == nil { node.needsDiagnosis = true }
            node.flags[flag] = reason
        case .flagCleared(let flag):
            if flag == .escalated { node.needsDiagnosis = false }
            node.flags[flag] = nil
        case .diagnosisRecorded: node.needsDiagnosis = false
        case .ticketClosed: node.ticketClosed = true
        case .ticketReopened: node.ticketClosed = false
        case .attemptsReset:
            node.failedAttempts = 0
            node.recentFailures = []
        case .overlapHoldStarted(let waitingFor, let paths, let components):
            node.overlapHold = OverlapHold(waitingFor: waitingFor, paths: paths, components: components)
        case .overlapHoldEnded:
            node.overlapHold = nil
        case .requirementBranchCreated(let branch, _):
            node.requirementBranch = branch
        case .requirementVerificationStarted:
            node.requirementVerificationStarted = true
            node.requirementVerification = nil
            node.requirementVerificationRetryPending = false
        case .requirementVerificationFinished(var evidence):
            evidence.recordedAt = event.at
            node.requirementVerification = evidence
        case .requirementVerificationRetryRequested:
            if event.by.isHuman { node.requirementVerificationRetryPending = true }
        case .requirementMerged:
            node.requirementMerged = true
        case .requirementPullRequestOpened(let number, let url),
             .requirementPullRequestReopened(let number, let url):
            node.pullRequestNumber = number
            node.pullRequestURL = url
            node.pullRequestState = .open
            node.flags[.needsInput] = nil
        case .requirementPullRequestMerged(let number, let url):
            node.pullRequestNumber = number
            node.pullRequestURL = url
            node.pullRequestState = .merged
            node.requirementMerged = true
            node.flags[.needsInput] = nil
            node.publicationFailure = nil
            node.publicationRetryPending = false
        case .requirementPullRequestClosed(let number, let url):
            node.pullRequestNumber = number
            node.pullRequestURL = url
            node.pullRequestState = .closed
            node.flags[.needsInput] = "Pull request \(url) was closed without merging. Add harness:retry to push and reopen the same pull request."
        case .requirementPublicationStarted:
            node.publicationFailure = "Publication was interrupted. Check origin and the pull request, then add harness:retry to push and update the same pull request."
            node.publicationRetryPending = false
        case .requirementPublicationFinished(let commit):
            node.publishedCommit = commit
            node.publicationFailure = nil
            node.publicationRetryPending = false
        case .requirementPublicationFailed(let error):
            node.publicationFailure = error
            node.publicationRetryPending = false
        case .requirementPublicationRetryRequested:
            if event.by.isHuman {
                node.publicationRetryPending = true
                if node.pullRequestState == .closed { node.flags[.needsInput] = nil }
            }
        case .acceptanceCriterionProofsRecorded(let proofs):
            node.acceptanceCriterionProofs = proofs
        case .requirementBranchObserved(let branch, let tip, let main, let contained):
            node.requirementBranch = branch
            node.requirementBranchObservation = RequirementBranchObservation(
                tip: tip, main: main, containedInMain: contained)
        case .requirementCatchUpConflicted(let branch, let main, let files, let tickets):
            node.requirementBranch = branch
            node.catchUpConflict = CatchUpConflict(mainSHA: main, files: files, tickets: tickets)
        case .catchUpConflicted(let main, let files, let tickets):
            node.catchUpConflict = CatchUpConflict(mainSHA: main, files: files, tickets: tickets)
        case .catchUpSucceeded(let main, let tip, let method):
            node.catchUpConflict = nil
            node.lastCatchUpSuccess = CatchUpSuccess(mainSHA: main, newAgentOSMainTip: tip, method: method)
        case .testsFixed(let digest):
            node.testsDigest = digest
            node.testDraft = nil
            node.openTestProblem = nil
            node.updatedOtherTests = []
            node.updatedOtherTestsDigest = nil
        case .otherTestsUpdated(let files, let digest):
            node.updatedOtherTests = files
            node.updatedOtherTestsDigest = digest
        case .reviewRecorded(var review):
            review.recordedAt = event.at
            node.reviews.append(review)
            if !review.result.passed && review.stage == .acceptanceTests {
                // Reviewers sometimes file problems with the tests under testFindings at this stage too.
                let findings = review.result.allFindings
                node.latestTestFeedback = findings.isEmpty
                    ? "The review of these acceptance tests didn't pass but named no problem."
                    : findings.joined(separator: "\n")
            }
            if review.stage == .change {
                node.reviewFeedbackAnswered = false
                node.latestReviewFeedback = review.result.passed || review.result.findings.isEmpty
                    ? nil : review.result.findings.joined(separator: "\n")
                if !review.result.passed, let tests = review.result.testFindings, !tests.isEmpty {
                    node.latestTestFeedback = tests.joined(separator: "\n")
                }
            }
        case .humanReviewRequested(let commit):
            node.pendingHumanReview = commit
            node.approvedReviewCommit = nil
        case .humanReviewApproved(let commit):
            if event.by.isHuman, node.pendingHumanReview == commit {
                node.pendingHumanReview = nil
                node.approvedReviewCommit = commit
            }
        case .expectedAPIReported(let api): node.expectedAPI = api
        case .brokenTestReported(let report):
            node.brokenTestReports.append(report)
            // With the name: a test of other work is one the test author may not know.
            node.latestTestFeedback = "\(report.testName): \(report.reason)"
            node.openTestProblem = report.reason
        case .runStarted(let run, let role):
            node.activeRun = ActiveRun(run: run, role: role, since: event.at)
            if role != .verifier { node.startedAgentRuns.insert(run) }
            if role == .testAuthor || role == .implementer { node.agentRunsSinceHuman += 1 }
            // The new run took the draft over: it keeps its own if it fails too.
            if role == .testAuthor { node.testDraft = nil }
        case .runFinished: node.activeRun = nil
        case .agentCreditsRecorded(let run, let credits), .runCostRecorded(let run, let credits):
            node.recordedAICredits += credits
            node.runsWithRecordedCost.insert(run)
        case .changeSubmitted(let run, let commit):
            node.latestReviewFeedback = nil
            node.pendingHumanReview = nil
            node.approvedReviewCommit = nil
            node.lastSubmission = Submission(run: run, commit: commit)
            node.landingReworkPending = false
            node.landingRerunPending = false
        case .actualChangedFilesRecorded(let files):
            node.actualChangedFiles = files
        case .predictedPathsExpanded(let files):
            node.spec.predictedPaths.append(contentsOf: files)
        case .landingReworkNeeded(var evidence):
            evidence.recordedAt = event.at
            node.evidence.append(evidence)
            node.landingReworkPending = true
            node.landingRerunPending = false
        case .landingRerunRequested:
            node.landingReworkPending = false
            node.landingRerunPending = true
        case .reworkNeeded:
            node.latestReviewFeedback = nil
            node.reworks += 1
            node.lastSubmission = nil
            node.actualChangedFiles = nil
        case .landed(let commit):
            node.landedCommit = commit
            node.landedAt = record.position
            node.landingReworkPending = false
            node.landingRerunPending = false
            // A new landing is not covered by an earlier ancestry observation.
            if let root = lineage(of: id).last, let observation = root.requirementBranchObservation {
                let updated = RequirementBranchObservation(tip: commit, main: observation.main, containedInMain: false)
                if root.id == id {
                    node.requirementBranchObservation = updated
                } else {
                    nodes[root.id]?.requirementBranchObservation = updated
                }
            }
        case .questionsRaised(let role, let questions):
            node.openQuestions = questions
            // Tests written on a guess aren't kept: they start over once the questions are answered.
            if role == .testAuthor { node.testDraft = nil }
        case .testDraftKept(_, let files): node.testDraft = files.isEmpty ? nil : files
        case .signalAccepted(_, .retest, _): node.testDraft = nil
        case .assumptionsReported(let role, let assumptions): node.assumptions[role] = assumptions.isEmpty ? nil : assumptions
        case .suggestionsReported(let role, let questions):
            node.suggestedAnswers[role] = questions.isEmpty ? nil : SuggestedAnswers(questions: questions, reportedAt: event.at)
        case .questionsAnswered(var clarification):
            clarification.answeredAt = event.at
            node.clarifications.append(clarification)
            node.openQuestions = []
            node.reviewFeedbackAnswered = true
        case .attemptFailed(let summary):
            // A failed run (a timeout, say) addressed nothing: the change review's findings still stand for the retry.
            node.failedAttempts += 1
            node.recentFailures.append(summary)
            node.landingReworkPending = false
            node.landingRerunPending = false
        case .acceptanceTestPreflightFailed(var evidence):
            evidence.recordedAt = event.at
            node.evidence.append(evidence)
            node.latestTestFeedback = evidence.details ?? evidence.summary
            node.openTestProblem = evidence.summary
        case .evidenceRecorded(var evidence):
            evidence.recordedAt = event.at
            node.evidence.append(evidence)
            if !evidence.passed { node.latestReviewFeedback = nil }
            // Final verification waits for a person; it is not another implementation attempt.
            if !evidence.passed && evidence.checkedBy != node.requirementVerification?.checkedBy
                && evidence.failureClassification != .runnerCrash
                && evidence.failureClassification != .landingInfrastructure
                && evidence.failureClassification != .unreliableTests {
                node.failedAttempts += 1
                node.recentFailures.append(evidence.summary)
            }
        default:
            break
        }
        nodes[id] = node
    }
}
