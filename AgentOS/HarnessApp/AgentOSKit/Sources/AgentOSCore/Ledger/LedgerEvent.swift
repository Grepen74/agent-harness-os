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

    // Lifecycle (doc 02 §6)
    case gateOpened(Gate)
    case phaseChanged(to: Phase)
    case flagSet(Flag, reason: String)
    case flagCleared(Flag)
    case attemptsReset

    // Work
    /// Fingerprint of the node's acceptance tests; nobody may change them afterwards.
    case testsFixed(digest: String)
    /// Claim + intent: written BEFORE the agent starts, so a crash can't run it twice unnoticed (doc 07 §3).
    case runStarted(run: RunID, role: AgentRole)
    case runFinished(run: RunID, outcome: String)
    case changeSubmitted(run: RunID, commit: String)
    case attemptFailed(summary: String)
    case evidenceRecorded(Evidence)
    /// A textual conflict at landing: the implementation is thrown away and redone on the latest code.
    /// Counted apart from failed attempts; it isn't the agent's fault (doc 08 §5).
    case reworkNeeded(reason: String)
    /// Merged into main: the node's change is now part of the product.
    case landed(commit: String)

    // Outside world
    case externalDependencyResolved(ref: String)

    // The repo (doc 01): what the harness knew about it when it started, and whenever that changed.
    case readinessScanned(ReadinessScan)
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
        case .gateOpened(let gate): "\(gate.rawValue) gate opened"
        case .phaseChanged(let phase): "→ \(phase.rawValue)"
        case .flagSet(let flag, let reason): "⚑ \(flag.rawValue): \(reason)"
        case .flagCleared(let flag): "⚑ \(flag.rawValue) cleared"
        case .attemptsReset: "attempts reset"
        case .testsFixed(let digest): "acceptance tests fixed (\(digest.prefix(8)))"
        case .runStarted(let run, let role): "\(role.rawValue) run \(run) started"
        case .runFinished(let run, let outcome): "run \(run) finished: \(outcome)"
        case .changeSubmitted(let run, let commit): "change submitted by \(run) (\(commit.prefix(8)))"
        case .attemptFailed(let summary): "attempt failed: \(summary)"
        case .evidenceRecorded(let evidence): "evidence: \(evidence.check) \(evidence.passed ? "passed" : "FAILED") – \(evidence.summary)"
        case .externalDependencyResolved(let ref): "\(ref) delivered"
        case .reworkNeeded(let reason): "rework: \(reason)"
        case .landed(let commit): "landed on main at \(commit.prefix(8))"
        case .readinessScanned(let scan):
            "readiness scan of \(scan.branch ?? "?") at \((scan.commit ?? "?").prefix(8)): \(scan.summary)"
        }
    }
}
