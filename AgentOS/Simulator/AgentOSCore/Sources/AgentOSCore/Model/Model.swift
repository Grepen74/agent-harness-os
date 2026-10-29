import Foundation

// Core vocabulary from the concept docs (00-overview, doc 02).

public typealias NodeID = String
public typealias RunID = String

/// Who did something. Every ledger event says who is responsible for it.
public enum Participant: Codable, Sendable, Hashable {
    case human(String)
    case agent(run: RunID, role: AgentRole)
    case reconciler
    /// Adapters only report what they observed in another system.
    case adapter(String)

    public var label: String {
        switch self {
        case .human(let name): name
        case .agent(let run, let role): "\(role.rawValue) agent (\(run))"
        case .reconciler: "reconciler"
        case .adapter(let name): "\(name) adapter"
        }
    }

    public var isHuman: Bool {
        if case .human = self { return true }
        return false
    }
}

public enum AgentRole: String, Codable, Sendable {
    case decomposer, testAuthor, implementer, verifier
}

/// Lifecycle phases (doc 02 §6).
/// Omitted in the mock: draft, closed, cancelled, superseded.
public enum Phase: String, Codable, Sendable {
    /// `checking`: own tests on the leaf's branch. `landing`: in the landing queue (doc 08).
    case specified, split, ready, building, checking, landing, proven
}

/// Flags sit on top of the phase (doc 02 §6).
/// Omitted in the mock: stale (spec changes, doc 02 §9) and paused (doc 05).
public enum Flag: String, Codable, Sendable, CaseIterable {
    case escalated, blocked
}

/// Permissions for one kind of work, opened by a deliberate human signal (doc 05).
public enum Gate: String, Codable, Sendable, CaseIterable {
    case breakdown, build
}

public enum NodeKind: String, Codable, Sendable {
    /// Needs breakdown into children.
    case composite
    /// One atomic change in one repo; may touch several components (doc 08 §1).
    case leaf
    // Production also has integration nodes (doc 02 §5). They're needed across repos; inside one repo the
    // landing queue already checks everything together (doc 08 §6), so the single-repo mock has none.
}

/// Typed links (doc 02 §2). The mock uses one of the seven types.
public enum LinkType: String, Codable, Sendable {
    case dependsOn = "depends-on"
}

public struct TypedLink: Codable, Sendable, Hashable {
    public let from: NodeID
    public let type: LinkType
    /// A node ID, or an external reference such as "BACKEND-42".
    public let to: String
}

/// The specification part of a Work Node: what, why, how we know it's done, and where.
public struct NodeSpec: Codable, Sendable, Hashable, Identifiable {
    public var id: NodeID
    public var parent: NodeID?
    public var kind: NodeKind
    public var title: String
    public var intent: String
    public var acceptanceCriteria: [String]
    /// The touch set: components (Swift modules in the monorepo) this leaf expects to change (doc 08 §1).
    /// A prediction, not a fence.
    public var touches: [String] = []
    /// External items this node needs, e.g. "BACKEND-42" (become `depends-on` links).
    public var dependsOn: [String] = []
    /// Production: a profile name selects checks, reviews and permissions (doc 02 §3).
    public var profile: String = "simple-app"

    /// The spec fingerprint (`spec_hash`). Evidence only counts for the fingerprint it was produced for.
    public var specHash: String {
        Hashing.sha256(Hashing.canonicalJSON([title, intent] + acceptanceCriteria))
    }

    /// The node's own test target: its acceptance tests belong to the node, not to a component (doc 08 §2).
    public var testTarget: String {
        let name = id.replacingOccurrences(of: "wn-", with: "")
            .map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return name + "Tests"
    }
}

/// Proof that something was checked.
public struct Evidence: Codable, Sendable, Hashable {
    public var check: String
    public var passed: Bool
    public var summary: String
    public var specHash: String
    /// The implementer run whose change was checked.
    public var builtBy: RunID
    /// Must differ from `builtBy`: builder ≠ checker. Enforced by the ledger.
    public var checkedBy: RunID
    /// The full log lives in artifact storage; the ledger keeps only the path and checksum.
    public var artifactPath: String
    public var artifactSHA256: String
    /// The git commit that was checked. One commit pins every component at once, so which versions were
    /// tested together is never ambiguous (doc 08 §2).
    public var commit: String
}

/// Requests a human can make through a label (doc 05). Labels are one-time requests.
/// Omitted in the mock: preview with notes, pause, resume, withdraw.
public enum HarnessCommand: String, Codable, Sendable, CaseIterable {
    case preview, breakdown, build, retry

    public var label: String { "harness:\(rawValue)" }
}
