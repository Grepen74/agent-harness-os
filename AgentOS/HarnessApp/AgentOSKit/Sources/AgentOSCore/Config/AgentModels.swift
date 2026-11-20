import Foundation

/// The model each agent role uses. nil means the agent CLI's own default.
/// The harness settings offer models and pick a default per role; a repo may only choose among the offered ones.
public typealias AgentModels = AgentRoleValues<String>

/// The reasoning effort each agent role uses. nil means the agent CLI's own default.
public typealias AgentEfforts = AgentRoleValues<ReasoningEffort>

/// One optional value per agent role.
public struct AgentRoleValues<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var decomposer: Value?
    public var testAuthor: Value?
    public var implementer: Value?

    /// The roles that are agents (verification is plain checks run by the harness).
    public static var roles: [AgentRole] { [.decomposer, .testAuthor, .implementer] }

    public init(decomposer: Value? = nil, testAuthor: Value? = nil, implementer: Value? = nil) {
        self.decomposer = decomposer
        self.testAuthor = testAuthor
        self.implementer = implementer
    }

    public subscript(role: AgentRole) -> Value? {
        get {
            switch role {
            case .decomposer: decomposer
            case .testAuthor: testAuthor
            case .implementer: implementer
            case .verifier, .diagnoser: nil
            }
        }
        set {
            switch role {
            case .decomposer: decomposer = newValue
            case .testAuthor: testAuthor = newValue
            case .implementer: implementer = newValue
            case .verifier, .diagnoser: break
            }
        }
    }
}

/// How hard an agent thinks (`copilot --reasoning-effort`). Which levels a model supports depends on the model.
public enum ReasoningEffort: String, Codable, Sendable, CaseIterable, Comparable {
    case none, minimal, low, medium, high, xhigh, max

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// The model and reasoning effort an agent run starts with, as recorded in the ledger and the agent's log.
public struct AgentRunSettings: Codable, Sendable, Equatable {
    /// The model, e.g. `gpt-6.1-sol`, or `the CLI's default (your setting: gpt-6.1-sol)` when the harness didn't
    /// choose one.
    public var model: String
    public var effort: String
    /// Set when the run fell back to these from what it started with: why, e.g. the model doesn't support the effort.
    public var fallback: String?

    public init(model: String, effort: String, fallback: String? = nil) {
        self.model = model
        self.effort = effort
        self.fallback = fallback
    }
}

/// Where an agent adapter reports credit usage and settings a run fell back to, for the harness to record.
/// The harness sets one around each agent run it records.
public final class AgentRunRecording: @unchecked Sendable {
    @TaskLocal public static var current: AgentRunRecording?

    private let lock = NSLock()
    private var settings: AgentRunSettings?
    private var credits: Double?

    public init() {}

    /// The settings the run fell back to; nil when it ran with the ones it started with.
    public var fellBack: AgentRunSettings? { lock.withLock { settings } }

    public func record(fallback settings: AgentRunSettings) { lock.withLock { self.settings = settings } }

    /// Incremental usage for this run; an explicit zero still reports a known cost.
    public func record(credits: Double) {
        lock.withLock { self.credits = (self.credits ?? 0) + credits }
    }

    var recordedCredits: Double? { lock.withLock { credits } }
}

extension AgentRole {
    /// What the role does, for settings and panes.
    public var job: String {
        switch self {
        case .decomposer: "Breakdown"
        case .testAuthor: "Acceptance tests"
        case .implementer: "Implementation"
        case .verifier: "Verification"
        case .diagnoser: "Diagnosis"
        }
    }
}
