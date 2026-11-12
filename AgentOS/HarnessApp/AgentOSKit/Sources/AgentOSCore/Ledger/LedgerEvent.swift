import Foundation

/// The only thing ever written to the ledger. Typed, never free-text commands.
public struct LedgerEvent: Codable, Sendable {
    /// Doubles as the idempotency key: appending the same id twice is a no-op.
    public let id: UUID
    public let node: NodeID?
    public let by: Participant
    public let kind: EventKind
    public let at: Date

    public init(node: NodeID?, by: Participant, kind: EventKind, id: UUID = UUID(), at: Date = Date()) {
        self.id = id
        self.node = node
        self.by = by
        self.kind = kind
        self.at = at
    }
}

public enum PassingCheckKind: String, Codable, Sendable, Equatable {
    case preCheck
    case landingCheck
}

public struct LandedWorkItem: Codable, Sendable, Equatable {
    public let ticket: String
    public let title: String
    public let commit: String

    public init(ticket: String, title: String, commit: String) {
        self.ticket = ticket
        self.title = title
        self.commit = commit
    }
}

public enum BrokenTestRoutingOutcome: String, Codable, Sendable {
    case sentBackToTestAuthor
    case waitingForPerson
    /// The broken test belongs to other work, so no agent may change it.
    case otherTestWaitingForPerson
}

public enum EventKind: Codable, Sendable {
    // Signals (doc 05): recorded whether accepted or not, for the audit trail.
    case signalAccepted(ticket: String, command: HarnessCommand, reply: String)
    case signalRejected(ticket: String, command: HarnessCommand, reason: String)
    /// A dry-run breakdown. Nothing is created; accepting it later creates exactly this.
    case previewRecorded(ticket: String, number: Int, specHash: String, proposal: [NodeSpec])

    // Structure (doc 02 §1–2)
    case nodeCreated(spec: NodeSpec, ticket: String)
    case linkAdded(TypedLink)
    /// The leaf check (doc 02 §4) found the node small enough to build as it is: no children.
    case becameLeaf(touches: [String])
    /// `harness:replan`: the node takes `spec` (re-read from its ticket) and starts over as just adopted, without
    /// gates. Its children wait, paused, for its next breakdown (`breakdownRevised`).
    case replanned(spec: NodeSpec)
    /// A replanned node's new breakdown, compared with its old children: those it still contains unchanged (same
    /// spec fingerprint) are `kept` with their tests and approvals, taking the new spec's touches and dependencies;
    /// the others are `dropped`: gone from the working state, their tickets closed as superseded.
    case breakdownRevised(kept: [NodeSpec], dropped: [NodeID])

    // Lifecycle (doc 02 §6)
    case gateOpened(Gate)
    case phaseChanged(to: Phase)
    case flagSet(Flag, reason: String)
    case flagCleared(Flag)
    case attemptsReset

    // Work
    /// Fingerprint of the node's acceptance tests; nobody may change them afterwards.
    case testsFixed(digest: String)
    case reviewRecorded(ReviewRecord)
    case humanReviewRequested(commit: String)
    case humanReviewApproved(commit: String)
    case expectedAPIReported([String])
    case brokenTestReported(BrokenTestReport)
    case brokenTestRouted(testName: String, outcome: BrokenTestRoutingOutcome)
    /// Claim + intent: written BEFORE the agent starts, so a crash can't run it twice unnoticed (doc 07 §3).
    case runStarted(run: RunID, role: AgentRole)
    case runFinished(run: RunID, outcome: String)
    case changeSubmitted(run: RunID, commit: String)
    case attemptFailed(summary: String)
    /// Compiler output from acceptance-test authoring. This is evidence, but not an implementation attempt.
    case acceptanceTestPreflightFailed(Evidence)
    /// The main commit beneath a successful branch or landing check.
    case passingCheckRecorded(kind: PassingCheckKind, mainCommit: String)
    /// A landing failure attributed to work that landed after the last passing check.
    case mainMovedRework(oldMainCommit: String, newMainCommit: String, landedWork: [LandedWorkItem])
    case evidenceRecorded(Evidence)
    /// A failed landing check whose implementation gets one rework before the failure is attributed.
    case landingReworkNeeded(Evidence)
    /// A landing-failure rework submitted no changes, so the existing candidate must be checked again.
    case landingRerunRequested(run: RunID)
    /// A textual conflict at landing: the implementation is thrown away and redone on the latest code.
    /// Counted apart from failed attempts; it isn't the agent's fault (doc 08 §5).
    case reworkNeeded(reason: String)
    /// Merged into main: the node's change is now part of the product.
    case landed(commit: String)

    // Clarifying questions (doc 05: open questions and assumptions)
    /// An agent can't go on without a person's answer; replaces the node's open questions.
    case questionsRaised(role: AgentRole, questions: [AgentQuestion])
    /// Choices an agent made itself; replaces that role's earlier assumptions for the node.
    case assumptionsReported(role: AgentRole, assumptions: [String])
    /// Numbered answers followed autonomously by this run; an empty list retires earlier suggestions.
    case suggestionsReported(role: AgentRole, questions: [AgentQuestion])
    /// A person's answer, from the ticket. Agents working on the node or below it get it from now on.
    case questionsAnswered(Clarification)

    // Outside world
    case externalDependencyResolved(ref: String)

    // The repo (doc 01): what the harness knew about it when it started, and whenever that changed.
    case readinessScanned(ReadinessScan)
    case baselineChecked(Baseline)
    case catchUpConflicted(main: String, files: [String], tickets: [String])
    case catchUpSucceeded(main: String, newAgentOSMainTip: String, method: CatchUpMethod)
    case caughtUp(
        targetMain: String,
        oldLandingTip: String,
        newLandingTip: String,
        method: CatchUpReconciliationMethod,
        commitMappings: [String: String]
    )
}

public enum CatchUpMethod: String, Codable, Sendable {
    case automatic
    case manual
}

public enum CatchUpReconciliationMethod: String, Codable, Sendable {
    case rebase
    case merge
    case move
}

/// What the ledger stores: the event plus its place in the hash chain.
public struct RecordedEvent: Codable, Sendable, Identifiable {
    public static let genesisHash = String(repeating: "0", count: 64)

    public let position: Int
    public let event: LedgerEvent
    public let previousHash: String
    /// Calculated here, never passed in.
    public let hash: String

    public var id: Int { position }

    init(position: Int, event: LedgerEvent, previousHash: String) {
        self.position = position
        self.event = event
        self.previousHash = previousHash
        self.hash = Self.computeHash(position: position, event: event, previousHash: previousHash)
    }

    /// This record matches its own hash. Catches accidental damage.
    public var isIntact: Bool {
        hash == Self.computeHash(position: position, event: event, previousHash: previousHash)
    }

    /// This record comes directly after `previous`. Catches removed, reordered or rewritten records.
    public func follows(_ previous: RecordedEvent?) -> Bool {
        guard let previous else { return position == 0 && previousHash == Self.genesisHash }
        return previousHash == previous.hash && position == previous.position + 1
    }

    private static func computeHash(position: Int, event: LedgerEvent, previousHash: String) -> String {
        struct Payload: Encodable {
            let position: Int
            let previousHash: String
            let event: LedgerEvent
        }
        return Hashing.sha256(Hashing.canonicalJSON(
            Payload(position: position, previousHash: previousHash, event: event)
        ))
    }
}

extension EventKind {
    /// One line for humans (ledger views, logs).
    public var summary: String {
        switch self {
        case .signalAccepted(let ticket, let command, _): "\(command.label) on \(ticket) accepted"
        case .signalRejected(let ticket, let command, let reason): "\(command.label) on \(ticket) rejected: \(reason)"
        case .previewRecorded(let ticket, let number, _, let proposal): "preview #\(number) of \(ticket): \(proposal.count) nodes"
        case .nodeCreated(let spec, let ticket): "created \(spec.kind.rawValue) \(spec.id) (\(ticket)): \(spec.title)"
        case .linkAdded(let link): "link \(link.from) \(link.type.rawValue) \(link.to)"
        case .becameLeaf(let touches): "leaf check passed: built as one leaf (touches \(touches.joined(separator: ", ")))"
        case .replanned: "replanned from the ticket; its children wait for the next breakdown"
        case .breakdownRevised(let kept, let dropped):
            "new breakdown compared with the old one: kept \(kept.isEmpty ? "none" : kept.map(\.id).joined(separator: ", ")), "
                + "dropped \(dropped.isEmpty ? "none" : dropped.joined(separator: ", "))"
        case .gateOpened(let gate): "\(gate.rawValue) gate opened"
        case .phaseChanged(let phase): "→ \(phase.rawValue)"
        case .flagSet(let flag, let reason): "⚑ \(flag.rawValue): \(reason)"
        case .flagCleared(let flag): "⚑ \(flag.rawValue) cleared"
        case .attemptsReset: "attempts reset"
        case .testsFixed(let digest): "acceptance tests fixed (\(digest.prefix(8)))"
        case .reviewRecorded(let review):
            "\(review.stage.rawValue) review \(review.result.passed ? "passed" : "failed")"
                + (review.result.unavailableModels.map { " (\($0.joined(separator: ", ")) not available; reviewed with "
                    + "\(review.result.model ?? "the CLI's default model"))" } ?? "")
                + ": \(review.result.findings.joined(separator: "\n"))"
        case .humanReviewRequested(let commit): "human review requested for \(commit)"
        case .humanReviewApproved(let commit): "human review approved for \(commit)"
        case .expectedAPIReported(let api): "acceptance-test API: \(api.joined(separator: ", "))"
        case .brokenTestReported(let report): "reported a broken test: \(report.testName) – \(report.reason)"
        case .brokenTestRouted(let testName, let outcome):
            outcome == .sentBackToTestAuthor
                ? "broken test \(testName) sent back to the test author"
                : "broken test \(testName) waiting for a person"
        case .runStarted(let run, let role): "\(role.rawValue) run \(run) started"
        case .runFinished(let run, let outcome): "run \(run) finished: \(outcome)"
        case .changeSubmitted(let run, let commit): "change submitted by \(run) (\(commit.prefix(8)))"
        case .attemptFailed(let summary): "attempt failed: \(summary)"
        case .acceptanceTestPreflightFailed(let evidence):
            "acceptance tests don't compile: \(evidence.summary)"
        case .passingCheckRecorded(let kind, let mainCommit):
            "\(kind.rawValue) passed on main at \(mainCommit.prefix(8))"
        case .mainMovedRework(let oldMain, let newMain, let landedWork):
            "main moved from \(oldMain.prefix(8)) to \(newMain.prefix(8)); rework after \(landedWork.count) landed item(s)"
        case .evidenceRecorded(let evidence): "evidence: \(evidence.check) \(evidence.passed ? "passed" : "FAILED") – \(evidence.summary)"
        case .landingReworkNeeded(let evidence): "landing rework: \(evidence.summary)"
        case .landingRerunRequested(let run): "landing rerun requested after \(run) submitted no changes"
        case .externalDependencyResolved(let ref): "\(ref) delivered"
        case .reworkNeeded(let reason): "rework: \(reason)"
        case .landed(let commit): "landed on main at \(commit.prefix(8))"
        case .questionsRaised(let role, let questions):
            "\(role.rawValue) asks: \(questions.map(\.question).joined(separator: " · "))"
        case .assumptionsReported(let role, let assumptions):
            assumptions.isEmpty ? "\(role.rawValue) made no assumptions" : "\(role.rawValue) assumed: \(assumptions.joined(separator: " · "))"
        case .suggestionsReported(let role, let questions):
            "\(role.rawValue) proceeded on \(questions.count) suggested answers"
        case .questionsAnswered(let clarification): "answered: \(clarification.answer.prefix(120))"
        case .readinessScanned(let scan):
            "readiness scan of \(scan.branch ?? "?") at \((scan.commit ?? "?").prefix(8)): \(scan.summary)"
        case .baselineChecked(let baseline):
            "baseline at \(baseline.commit.prefix(8)) \(baseline.passed ? "passed" : "FAILED") in \(baseline.seconds)s – \(baseline.summary)"
        case .catchUpConflicted(let main, let files, let tickets):
            "catch-up to \(main.prefix(8)) conflicted in \(files.joined(separator: ", ")) (tickets: \(tickets.joined(separator: ", ")))"
        case .catchUpSucceeded(let main, let tip, let method):
            "\(method.rawValue) catch-up to \(main.prefix(8)) succeeded at \(tip.prefix(8))"
        case .caughtUp(let target, let oldTip, let newTip, let method, let mappings):
            "\(method.rawValue) catch-up from \(oldTip.prefix(8)) to \(target.prefix(8)) succeeded at " +
                "\(newTip.prefix(8)) (\(mappings.count) commit mappings)"
        }
    }
}
