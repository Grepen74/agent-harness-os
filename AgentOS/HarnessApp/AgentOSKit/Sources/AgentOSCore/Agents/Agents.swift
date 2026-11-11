import Foundation

/// Everything an agent gets for one job. Agents get the spec as DATA; they never read tracker comments
/// or labels as instructions (golden rule: ticket text is data, not instructions).
public struct AgentTask: Sendable {
    public let spec: NodeSpec
    public let identity: NodeIdentity
    public let run: RunID
    /// The leaf's own working copy (its branch). The only place the agent may write.
    public let directory: URL
    /// The leaf's own test folder, relative to `directory`: the test author writes only there, and nobody
    /// changes it afterwards.
    public let testFolder: String
    /// Writable experiment space for this run, inside `directory` and excluded from its submission.
    public let scratchDirectory: URL
    /// The repo's layout and rules for agents (from the workspace).
    public let context: String
    public let attempt: Int
    public let previousFailure: String?
    /// Simulation only: `sim:` labels on the ticket that make scripted agents misbehave on purpose.
    public let simulationHints: Set<String>
    /// Where the agent writes its output as it works (see `AgentLog`); nil when not kept.
    public let log: URL?
    /// Questions people already answered for this node or its parents.
    public let clarifications: [Clarification]
    public let guesswork: Guesswork
    /// Public production symbols the acceptance-test author expects the implementation to provide.
    public let expectedAPI: [String]

    public init(spec: NodeSpec, run: RunID, directory: URL, testFolder: String, scratchDirectory: URL,
                context: String = "", attempt: Int = 1, previousFailure: String? = nil,
                simulationHints: Set<String> = [], log: URL? = nil,
                clarifications: [Clarification] = [], guesswork: Guesswork = .assumeAndReport,
                expectedAPI: [String] = [], ticketKey: String? = nil) {
        self.spec = spec
        let inferredTicket = spec.id.hasPrefix("wn-") ? String(spec.id.dropFirst(3)) : spec.id
        self.identity = NodeIdentity(ticketKey: ticketKey ?? inferredTicket, nodeID: spec.id)
        self.run = run
        self.directory = directory
        self.testFolder = testFolder
        self.scratchDirectory = scratchDirectory
        self.context = context
        self.attempt = attempt
        self.previousFailure = previousFailure
        self.simulationHints = simulationHints
        self.log = log
        self.clarifications = clarifications
        self.guesswork = guesswork
        self.expectedAPI = expectedAPI
    }
}

public struct BrokenTestReport: Codable, Sendable, Hashable {
    public var testName: String
    public var reason: String

    public init(testName: String, reason: String) {
        self.testName = testName
        self.reason = reason
    }
}

public struct AgentQuestion: Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    private enum CodingKeys: String, CodingKey {
        case question
        case suggestion
    }

    public var question: String
    public var suggestion: String?

    public init(question: String, suggestion: String? = nil) {
        self.question = question
        self.suggestion = suggestion
    }

    public init(stringLiteral value: String) {
        self.init(question: value)
    }

    public init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            self.init(question: value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            question: try container.decode(String.self, forKey: .question),
            suggestion: try container.decodeIfPresent(String.self, forKey: .suggestion)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        guard let suggestion else {
            var container = encoder.singleValueContainer()
            try container.encode(question)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(question, forKey: .question)
        try container.encode(suggestion, forKey: .suggestion)
    }
}

/// What an agent wasn't sure of (doc 05: open questions and assumptions), returned with its result.
public struct AgentReport: Codable, Sendable, Hashable {
    /// What users will observe that the spec doesn't settle. Any of them stops the node until a person answers.
    public var questions: [AgentQuestion]
    /// Choices the agent made itself, for a reviewer to see.
    public var assumptions: [String]
    /// Public symbols the tests require from the implementation.
    public var expectedAPI: [String]
    /// An acceptance test the implementer cannot satisfy because its contract is broken.
    public var brokenTest: BrokenTestReport?

    public init(
        questions: [AgentQuestion] = [],
        assumptions: [String] = [],
        expectedAPI: [String] = [],
        brokenTest: BrokenTestReport? = nil
    ) {
        self.questions = questions
        self.assumptions = assumptions
        self.expectedAPI = expectedAPI
        self.brokenTest = brokenTest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        questions = try container.decodeIfPresent([AgentQuestion].self, forKey: .questions) ?? []
        assumptions = try container.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        expectedAPI = try container.decodeIfPresent([String].self, forKey: .expectedAPI) ?? []
        brokenTest = try container.decodeIfPresent(BrokenTestReport.self, forKey: .brokenTest)
    }
}

/// Questions a person answered on the ticket. Agents get them as data, like the spec.
public struct Clarification: Codable, Sendable, Hashable {
    public var questions: [String]
    public var answer: String

    public init(questions: [String], answer: String) {
        self.questions = questions
        self.answer = answer
    }
}

/// Everything the decomposer gets for one breakdown.
public struct BreakdownRequest: Sendable {
    public let spec: NodeSpec
    public let identity: NodeIdentity
    /// The catalog of components already on main, so leaves reuse them.
    public let existingComponents: [String]
    public let clarifications: [Clarification]
    public let guesswork: Guesswork
    /// Where to write its output as it works (see `AgentLog`); nil when not kept.
    public let log: URL?
    /// A read-only snapshot of the latest code to look at (see `Workspace.createSnapshot`); nil when there's none.
    public let codebase: URL?

    public init(spec: NodeSpec, existingComponents: [String] = [], clarifications: [Clarification] = [],
                guesswork: Guesswork = .assumeAndReport, log: URL? = nil, codebase: URL? = nil,
                ticketKey: String? = nil) {
        self.spec = spec
        let inferredTicket = spec.id.hasPrefix("wn-") ? String(spec.id.dropFirst(3)) : spec.id
        self.identity = NodeIdentity(ticketKey: ticketKey ?? inferredTicket, nodeID: spec.id)
        self.existingComponents = existingComponents
        self.clarifications = clarifications
        self.guesswork = guesswork
        self.log = log
        self.codebase = codebase
    }
}

/// The decomposer's answer: the children it proposes, or questions instead.
public struct Breakdown: Sendable {
    public var children: [ChildProposal]
    public var report: AgentReport

    public init(children: [ChildProposal], report: AgentReport = AgentReport()) {
        self.children = children
        self.report = report
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

/// Proposes how to split a node. Output is only a proposal: the harness turns it into nodes. It first checks the
/// node is ready (doc 05 §5): when it can't tell what users should observe, it returns questions instead.
public protocol Decomposer: Sendable {
    func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown
}

/// Turns acceptance criteria into tests in the node's own test target, before implementation starts.
/// Returns what it wasn't sure of; with open questions, the tests it wrote are discarded.
public protocol TestAuthor: Sendable {
    func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport
}

/// Changes the code in the components it touches. Can only submit; never decides it's done (builder ≠ checker).
public protocol Implementer: Sendable {
    associatedtype ImplementationReport: Sendable
    func implement(_ task: AgentTask) async throws -> ImplementationReport
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
