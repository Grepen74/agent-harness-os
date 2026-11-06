import Foundation

/// The model each agent role uses. nil means the agent CLI's own default.
/// The harness settings offer models and pick a default per role; a repo may only choose among the offered ones.
public struct AgentModels: Codable, Sendable, Equatable {
    public var decomposer: String?
    public var testAuthor: String?
    public var implementer: String?

    /// The roles that are agents (verification is plain checks run by the harness).
    public static let roles: [AgentRole] = [.decomposer, .testAuthor, .implementer]

    public init(decomposer: String? = nil, testAuthor: String? = nil, implementer: String? = nil) {
        self.decomposer = decomposer
        self.testAuthor = testAuthor
        self.implementer = implementer
    }

    public subscript(role: AgentRole) -> String? {
        get {
            switch role {
            case .decomposer: decomposer
            case .testAuthor: testAuthor
            case .implementer: implementer
            case .verifier: nil
            }
        }
        set {
            switch role {
            case .decomposer: decomposer = newValue
            case .testAuthor: testAuthor = newValue
            case .implementer: implementer = newValue
            case .verifier: break
            }
        }
    }
}

extension AgentRole {
    /// What the role does, for settings and panes.
    public var job: String {
        switch self {
        case .decomposer: "Breakdown"
        case .testAuthor: "Acceptance tests"
        case .implementer: "Implementation"
        case .verifier: "Verification"
        }
    }
}
