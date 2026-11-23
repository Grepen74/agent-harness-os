import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

extension GH_112Tests {
    enum Observation: Sendable, Equatable {
        case push(String, String)
        case status(String, String, String)
        case checkStarted(String)
        case checkFinished(String, Bool)
    }

    actor Trace {
        private(set) var events: [Observation] = []
        func add(_ event: Observation) { events.append(event) }
    }

    struct Status: Sendable, Equatable {
        let commit: String
        let state: String
        let description: String
    }

    actor Git {
        struct Push: Sendable { let arguments: [String]; let commit: String }
        let workspace: Branches
        let trace: Trace
        private(set) var pushes: [Push] = []
        init(workspace: Branches, trace: Trace) { self.workspace = workspace; self.trace = trace }
        func run(_ arguments: [String]) async throws -> String {
            if arguments.first == "rev-parse" {
                let ref = try #require(arguments.last).replacingOccurrences(of: "refs/heads/", with: "")
                return try #require(await workspace.tip(of: ref)) + "\n"
            }
            if arguments.first == "push" {
                let refspec = try #require(arguments.last)
                let branch = String(try #require(refspec.split(separator: ":").first))
                    .replacingOccurrences(of: "refs/heads/", with: "")
                let commit = try #require(await workspace.tip(of: branch))
                pushes.append(Push(arguments: arguments, commit: commit))
                await trace.add(.push(branch, commit))
                return "Pushed \(commit)"
            }
            throw AgentFailure("Unexpected acceptance git command: \(arguments)")
        }
    }

    actor GitHub: GitHubTransport {
        let trace: Trace
        private var prs: [Int: String]
        private var nextNumber = 1000
        private(set) var statuses: [Status] = []
        private(set) var mutations: [String] = []
        private(set) var openedBranches: [String] = []
        private(set) var unexpected: [String] = []
        init(trace: Trace, pullRequests: [Root]) {
            self.trace = trace
            prs = Dictionary(uniqueKeysWithValues: pullRequests.compactMap {
                root in root.pullRequest.map { ($0, root.branch) }
            })
        }
        func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
            let resource = try #require(URLComponents(string: path)).path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let collection = "repos/\(GH_112Tests.repository)/pulls"
            let statusPrefix = "repos/\(GH_112Tests.repository)/statuses/"
            if method == "POST", resource.hasPrefix(statusPrefix) {
                let payload = try Self.object(body)
                let status = Status(
                    commit: String(resource.dropFirst(statusPrefix.count)),
                    state: try #require(payload["state"] as? String),
                    description: try #require(payload["description"] as? String))
                statuses.append(status)
                mutations.append("\(method) \(resource)")
                await trace.add(.status(status.commit, status.state, status.description))
                var response = payload
                response["id"] = statuses.count
                return try JSONSerialization.data(withJSONObject: response)
            }
            if method == "GET", resource == collection { return Data("[]".utf8) }
            if method == "GET", resource.hasPrefix(collection + "/"),
               let number = Int(resource.dropFirst(collection.count + 1)), let branch = prs[number] {
                return try Self.pr(number: number, branch: branch)
            }
            if method == "PATCH", resource.hasPrefix(collection + "/"),
               let number = Int(resource.dropFirst(collection.count + 1)), let branch = prs[number] {
                mutations.append("\(method) \(resource)")
                return try Self.pr(number: number, branch: branch)
            }
            if method == "POST", resource == collection {
                let branch = try #require(Self.object(body)["head"] as? String)
                nextNumber += 1
                prs[nextNumber] = branch
                openedBranches.append(branch)
                mutations.append("\(method) \(resource)")
                return try Self.pr(number: nextNumber, branch: branch)
            }
            unexpected.append("\(method) \(resource)")
            throw AgentFailure("Unexpected acceptance GitHub request: \(method) \(resource)")
        }
        private static func pr(number: Int, branch: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "number": number, "html_url": "https://github.com/acceptance/reverification/pull/\(number)",
                "state": "open", "merged_at": NSNull(), "head": ["ref": branch],
            ])
        }
        private static func object(_ data: Data?) throws -> [String: Any] {
            let data = try #require(data)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }

    actor Tracker: TrackerAdapter {
        private var tickets: [String: Ticket] = [:]
        private var signals: [Signal] = []
        nonisolated var contextRepository: String { GH_112Tests.repository }
        func add(_ ticket: Ticket) { tickets[ticket.key] = ticket }
        func retry(_ ticket: String) { signals.append(Signal(ticket: ticket, command: .retry, setBy: .human("Owner"))) }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? { tickets[key] }
        func contextTickets() async -> [Ticket] { Array(tickets.values) }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            comment(on: signal.ticket, reply)
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            throw AgentFailure("Reverification must not create child tickets")
        }
        func comment(on key: String, _ text: String) { tickets[key]?.comments.append(Comment(author: .reconciler, text: text)) }
        func setStatus(of key: String, to status: String) { tickets[key]?.status = status }
    }

    actor Agents: Decomposer, TestAuthor, Implementer {
        private(set) var calls: [AgentRole] = []
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            calls.append(.decomposer)
            throw AgentFailure("Reverification must not decompose work")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            calls.append(.testAuthor)
            throw AgentFailure("Reverification must not author tests")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            calls.append(.implementer)
            throw AgentFailure("Reverification must not start agent rework")
        }
    }

    struct External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
}
