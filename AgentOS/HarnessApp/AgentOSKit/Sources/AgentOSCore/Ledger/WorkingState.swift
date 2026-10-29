import Foundation

public struct ActiveRun: Sendable, Hashable {
    public let run: RunID
    public let role: AgentRole
}

public struct Submission: Sendable, Hashable {
    public let run: RunID
    public let commit: String
}

public struct Preview: Sendable, Hashable {
    public let number: Int
    public let specHash: String
    public let proposal: [NodeSpec]
}

/// The current state of one Work Node, derived from its events.
public struct NodeState: Sendable, Identifiable {
    public var id: NodeID { spec.id }
    public var spec: NodeSpec
    public var ticket: String
    /// Position of the last event that touched this node; used for compare-and-swap.
    public var version: Int
    public var phase: Phase = .specified
    public var flags: [Flag: String] = [:]
    public var gates: Set<Gate> = []
    public var links: [TypedLink] = []
    public var children: [NodeID] = []
    public var testsDigest: String?
    /// The claim: at most one agent run per node at a time.
    public var activeRun: ActiveRun?
    public var lastSubmission: Submission?
    public var evidence: [Evidence] = []
    public var failedAttempts = 0
    public var recentFailures: [String] = []
    public var reworks = 0
    /// Position in the landing queue (when it entered `landing`).
    public var queuedAt: Int?
    public var landedCommit: String?
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
    public private(set) var resolvedExternal: Set<String> = []
    /// The latest recorded readiness scan of the repo.
    public private(set) var readiness: ReadinessScan?

    public init() {}

    public var roots: [NodeState] {
        creationOrder.compactMap { nodes[$0] }.filter { $0.spec.parent == nil }
    }

    /// Leaves waiting to land, first come first served.
    public var landingQueue: [NodeState] {
        nodes.values.filter { $0.phase == .landing && $0.flags[.escalated] == nil && $0.activeRun == nil }
            .sorted { ($0.queuedAt ?? 0) < ($1.queuedAt ?? 0) }
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
        creationOrder.compactMap { nodes[$0] }.flatMap { node in
            Flag.allCases.compactMap { flag in node.flags[flag].map { (node, flag, $0) } }
        }
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

        switch event.kind {
        case .previewRecorded(let ticket, let number, let specHash, let proposal):
            previews[ticket] = Preview(number: number, specHash: specHash, proposal: proposal)
        case .externalDependencyResolved(let ref):
            resolvedExternal.insert(ref)
        case .readinessScanned(let scan):
            readiness = scan
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
        case .attemptsReset:
            node.failedAttempts = 0
            node.recentFailures = []
        case .testsFixed(let digest): node.testsDigest = digest
        case .runStarted(let run, let role): node.activeRun = ActiveRun(run: run, role: role)
        case .runFinished: node.activeRun = nil
        case .changeSubmitted(let run, let commit): node.lastSubmission = Submission(run: run, commit: commit)
        case .reworkNeeded:
            node.reworks += 1
            node.lastSubmission = nil
        case .landed(let commit): node.landedCommit = commit
        case .attemptFailed(let summary):
            node.failedAttempts += 1
            node.recentFailures.append(summary)
        case .evidenceRecorded(let evidence):
            node.evidence.append(evidence)
            if !evidence.passed {
                node.failedAttempts += 1
                node.recentFailures.append(evidence.summary)
            }
        default:
            break
        }
        nodes[id] = node
    }
}
