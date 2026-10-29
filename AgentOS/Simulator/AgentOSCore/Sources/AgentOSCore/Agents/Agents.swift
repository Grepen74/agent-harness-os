import Foundation

/// Everything an agent gets for one job. Agents get the spec as DATA; they never read tracker comments
/// or labels as instructions (golden rule: ticket text is data, not instructions).
public struct AgentTask: Sendable {
    public let spec: NodeSpec
    public let run: RunID
    /// The leaf's own working copy (its branch). The only place the agent may write.
    public let directory: URL
    public let attempt: Int
    public let previousFailure: String?
    /// Simulation only: `sim:` labels on the ticket that make scripted agents misbehave on purpose.
    public let simulationHints: Set<String>
}

/// A proposed child, before it becomes a Work Node.
public struct ChildProposal: Codable, Sendable {
    public var title: String
    public var acceptanceCriteria: [String]
    /// Components it expects to change (the touch set, doc 08 §1).
    public var touches: [String]?
    public var dependsOn: [String]?
}

public struct AgentFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Proposes how to split a node. Output is only a proposal: the harness turns it into nodes.
public protocol Decomposer: Sendable {
    /// `existingComponents`: the catalog of components already on main, so leaves reuse them.
    func proposeChildren(of parent: NodeSpec, existingComponents: [String]) async throws -> [ChildProposal]
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

    public static let scripted = AgentTeam(
        name: "Scripted", decomposer: ScriptedDecomposer(), testAuthor: ScriptedTestAuthor(),
        implementer: ScriptedImplementer())

    public static func copilot(_ cli: CopilotCLI) -> AgentTeam {
        AgentTeam(
            name: "Copilot CLI", decomposer: CopilotDecomposer(cli: cli), testAuthor: CopilotTestAuthor(cli: cli),
            implementer: CopilotImplementer(cli: cli))
    }
}
