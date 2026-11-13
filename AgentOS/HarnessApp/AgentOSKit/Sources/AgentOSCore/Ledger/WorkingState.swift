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
    public var flags: [Flag: String] = [:]
    /// A person closed the ticket: no more work, and its flags don't ask for attention.
    public var ticketClosed = false
    public var gates: Set<Gate> = []
    public var links: [TypedLink] = []
    public var children: [NodeID] = []
    public var testsDigest: String?
    public var expectedAPI: [String] = []
    public var brokenTestReports: [BrokenTestReport] = []
    /// The newest problem with this node's acceptance tests (broken-test report or failed compile), for the test author.
    public var latestTestFeedback: String?
    /// The claim: at most one agent run per node at a time.
    public var activeRun: ActiveRun?
    public var lastSubmission: Submission?
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
    public var landingReworkPending = false
    public var landingRerunPending = false
    public var reworks = 0
    /// Position in the landing queue (when it entered `landing`).
    public var queuedAt: Int?
    public var landedCommit: String?
    /// What an agent asked and nobody answered yet (with the `needsInput` flag).
    public var openQuestions: [AgentQuestion] = []
    /// Choices agents made themselves, per role (the decomposer's for a breakdown, the test author's for tests).
    public var assumptions: [AgentRole: [String]] = [:]
    public var suggestedAnswers: [AgentRole: SuggestedAnswers] = [:]
    /// Answers people gave on this node's ticket.
    public var clarifications: [Clarification] = []

    /// Every assumption on this node, decomposer first.
    public var allAssumptions: [String] {
        [AgentRole.decomposer, .testAuthor, .implementer, .verifier].flatMap { assumptions[$0] ?? [] }
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
            Flag.allCases.compactMap { flag in node.flags[flag].map { (node, flag, $0) } }
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
                                      breakdownWarnings: pendingBreakdownWarnings.removeValue(forKey: ticket) ?? [])
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

        switch event.kind {
        case .linkAdded(let link): node.links.append(link)
        case .becameLeaf(let touches):
            node.spec.kind = .leaf
            node.spec.touches = touches
        case .gateOpened(let gate): node.gates.insert(gate)
        case .phaseChanged(let phase):
            node.phase = phase
            node.queuedAt = phase == .landing ? record.position : nil
        case .flagSet(let flag, let reason): node.flags[flag] = reason
        case .flagCleared(let flag): node.flags[flag] = nil
        case .ticketClosed: node.ticketClosed = true
        case .ticketReopened: node.ticketClosed = false
        case .attemptsReset:
            node.failedAttempts = 0
            node.recentFailures = []
        case .testsFixed(let digest): node.testsDigest = digest
        case .reviewRecorded(let review):
            node.reviews.append(review)
            if !review.result.passed && review.stage == .acceptanceTests {
                node.latestTestFeedback = review.result.findings.joined(separator: "\n")
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
            node.latestTestFeedback = report.reason
        case .runStarted(let run, let role): node.activeRun = ActiveRun(run: run, role: role, since: event.at)
        case .runFinished: node.activeRun = nil
        case .changeSubmitted(let run, let commit):
            node.latestReviewFeedback = nil
            node.pendingHumanReview = nil
            node.approvedReviewCommit = nil
            node.lastSubmission = Submission(run: run, commit: commit)
            node.landingReworkPending = false
            node.landingRerunPending = false
        case .landingReworkNeeded(let evidence):
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
        case .landed(let commit):
            node.landedCommit = commit
            node.landingReworkPending = false
            node.landingRerunPending = false
        case .questionsRaised(_, let questions): node.openQuestions = questions
        case .assumptionsReported(let role, let assumptions): node.assumptions[role] = assumptions.isEmpty ? nil : assumptions
        case .suggestionsReported(let role, let questions):
            node.suggestedAnswers[role] = questions.isEmpty ? nil : SuggestedAnswers(questions: questions, reportedAt: event.at)
        case .questionsAnswered(let clarification):
            node.clarifications.append(clarification)
            node.openQuestions = []
            node.reviewFeedbackAnswered = true
        case .attemptFailed(let summary):
            node.latestReviewFeedback = nil
            node.failedAttempts += 1
            node.recentFailures.append(summary)
            node.landingReworkPending = false
            node.landingRerunPending = false
        case .acceptanceTestPreflightFailed(let evidence):
            node.evidence.append(evidence)
            node.latestTestFeedback = evidence.details ?? evidence.summary
        case .evidenceRecorded(let evidence):
            node.evidence.append(evidence)
            if !evidence.passed { node.latestReviewFeedback = nil }
            if !evidence.passed && evidence.failureClassification != .runnerCrash
                && evidence.failureClassification != .landingInfrastructure {
                node.failedAttempts += 1
                node.recentFailures.append(evidence.summary)
            }
        default:
            break
        }
        nodes[id] = node
    }
}
