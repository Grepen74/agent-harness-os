import Foundation

/// Everything an agent gets for one job. Agents get the spec as DATA; they never read tracker comments
/// or labels as instructions (golden rule: ticket text is data, not instructions).
public struct AgentTask: Sendable {
    public let spec: NodeSpec
    public let run: RunID
    /// The leaf's own working copy (its branch). The only place the agent may write.
    public let directory: URL
    /// The leaf's own test folder, relative to `directory`: the test author writes only there, and nobody
    /// changes it afterwards.
    public let testFolder: String
    /// The repo's layout and rules for agents (from the workspace).
    public let context: String
    public let attempt: Int
    public let previousFailure: String?
    /// Simulation only: `sim:` labels on the ticket that make scripted agents misbehave on purpose.
    public let simulationHints: Set<String>
    /// Where the agent writes its output as it works (see `AgentLog`); nil when not kept.
    public let log: URL?

    public init(spec: NodeSpec, run: RunID, directory: URL, testFolder: String, context: String = "", attempt: Int = 1,
                previousFailure: String? = nil, simulationHints: Set<String> = [], log: URL? = nil) {
        self.spec = spec
        self.run = run
        self.directory = directory
        self.testFolder = testFolder
        self.context = context
        self.attempt = attempt
        self.previousFailure = previousFailure
        self.simulationHints = simulationHints
        self.log = log
    }
}

/// A proposed child, before it becomes a Work Node.
public struct ChildProposal: Codable, Sendable {
    public var title: String
    public var acceptanceCriteria: [String]
    /// Components it expects to change (the touch set, doc 08 §1).
    public var touches: [String]?
    public var dependsOn: [String]?

    public init(title: String, acceptanceCriteria: [String], touches: [String]? = nil, dependsOn: [String]? = nil) {
        self.title = title
        self.acceptanceCriteria = acceptanceCriteria
        self.touches = touches
        self.dependsOn = dependsOn
    }
}

public struct AgentFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// An agent run changed repo state outside the harness's own branches (see `Workspace.userGitState`).
public struct UserGitStateChanged: Error, CustomStringConvertible {
    public let names: [String]
    /// Tickets whose agents ran at the same time: any of them may have made the change.
    public var alongside: [String] = []

    public init(names: [String], alongside: [String] = []) {
        self.names = names
        self.alongside = alongside
    }

    public var description: String {
        let check = "Check it (e.g. `git reflog`, `git config --list`); if you did this yourself while it ran, just retry."
        guard !alongside.isEmpty else {
            return "The agent changed your repo outside agentos/: \(names.joined(separator: ", ")). " + check
        }
        return "Your repo changed outside agentos/ while this agent ran: \(names.joined(separator: ", ")). "
            + "Agents for \(alongside.joined(separator: ", ")) ran at the same time, so it may have been one of them. " + check
    }
}

/// Proposes how to split a node. Output is only a proposal: the harness turns it into nodes.
public protocol Decomposer: Sendable {
    /// `existingComponents`: the catalog of components already on main, so leaves reuse them.
    /// `log`: where to write its output as it works (see `AgentLog`); nil when not kept.
    func proposeChildren(of parent: NodeSpec, existingComponents: [String], log: URL?) async throws -> [ChildProposal]
}

/// Turns acceptance criteria into tests in the node's own test target, before implementation starts.
public protocol TestAuthor: Sendable {
    func writeAcceptanceTests(_ task: AgentTask) async throws
}

/// Changes the code in the components it touches. Can only submit; never decides it's done (builder ≠ checker).
public protocol Implementer: Sendable {
    func implement(_ task: AgentTask) async throws
}

/// There is no verifier agent protocol: in the mock, verification is plain checks run by the harness
/// under a separate run ID. Production could add an AI reviewer as an extra, independent check.
public struct AgentTeam: Sendable {
    public let name: String
    public let decomposer: any Decomposer
    public let testAuthor: any TestAuthor
    public let implementer: any Implementer

    public init(name: String, decomposer: any Decomposer, testAuthor: any TestAuthor, implementer: any Implementer) {
        self.name = name
        self.decomposer = decomposer
        self.testAuthor = testAuthor
        self.implementer = implementer
    }
}
