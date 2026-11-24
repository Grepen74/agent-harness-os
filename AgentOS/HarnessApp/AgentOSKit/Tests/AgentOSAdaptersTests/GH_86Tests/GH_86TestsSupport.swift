import AgentOSCore
import Foundation
import Testing

extension GH_86Tests {
    struct CreditRow {
        let text: String
        let amount: String
    }

    static func link(_ ticket: String) -> String {
        "[\(ticket)](https://github.com/fixture/credits/issues/\(ticket.dropFirst(3)))"
    }

    static func rows(in comment: String) throws -> [CreditRow] {
        let expression = try NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s+AI credits"#)
        return try comment.components(separatedBy: .newlines).compactMap { line in
            let plain = line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
            let matches = expression.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
            guard !matches.isEmpty else { return nil }
            try #require(matches.count == 1, "Each credit line must report one amount: \(line)")
            let match = try #require(matches.first)
            let range = try #require(Range(match.range(at: 1), in: plain))
            return CreditRow(text: line, amount: String(plain[range]))
        }
    }

    final class Fixture: Sendable {
        let store: InMemoryLedgerStore
        let ledger: Ledger
        let tracker = MemoryTracker()
        let workspace = NoWorkWorkspace()

        init() throws {
            store = InMemoryLedgerStore()
            ledger = try Ledger(store: store)
        }

        func runner(ledger: Ledger) -> Reconciler {
            let unused = UnusedAgents()
            return Reconciler(
                ledger: ledger, tracker: tracker, external: NoExternal(),
                workspace: workspace, artifacts: MemoryArtifacts(), checks: UnusedChecks(),
                team: AgentTeam(name: "GH-86", decomposer: unused, testAuthor: unused, implementer: unused)
            )
        }

        @discardableResult
        func add(_ ticket: String, parent: NodeID? = nil, kind: NodeKind = .leaf) async throws -> NodeSpec {
            let spec = NodeSpec(
                id: "wn-\(ticket)", parent: parent, kind: kind, title: "Work for \(ticket)",
                intent: "Observe proven-parent cost comments", acceptanceCriteria: ["Cost is reported"]
            )
            await tracker.add(ticket, title: spec.title)
            try await ledger.append([
                LedgerEvent(node: spec.id, by: .reconciler, kind: .nodeCreated(spec: spec, ticket: ticket)),
                LedgerEvent(node: spec.id, by: .reconciler,
                            kind: .phaseChanged(to: kind == .composite ? .split : .ready)),
            ])
            return spec
        }

        func cost(
            _ ticket: String, credits: Double, role: AgentRole = .implementer, outcome: String = "finished"
        ) async throws {
            let run = "cost-\(UUID().uuidString)"
            try await ledger.append([
                LedgerEvent(node: "wn-\(ticket)", by: .reconciler, kind: .runStarted(run: run, role: role)),
                LedgerEvent(node: "wn-\(ticket)", by: .agent(run: run, role: role),
                            kind: .runCostRecorded(run: run, aiCredits: credits)),
                LedgerEvent(node: "wn-\(ticket)", by: .agent(run: run, role: role),
                            kind: .runFinished(run: run, outcome: outcome)),
            ])
        }

        func prove(_ tickets: String...) async throws {
            try await ledger.append(tickets.map {
                LedgerEvent(node: "wn-\($0)", by: .reconciler, kind: .phaseChanged(to: .proven))
            })
        }

        func settle(using existing: Reconciler? = nil) async throws {
            let reconciler = existing ?? runner(ledger: ledger)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            repeat {
                let report = await reconciler.runRound(waitForAgents: true)
                try #require(report.safeStop == nil, "Fixture must not safe-stop: \(report.safeStop ?? "")")
                if report.isIdle { return }
            } while ContinuousClock.now < deadline
            throw AgentFailure("GH-86 fixture did not become idle within ten seconds")
        }

        func costComment(_ ticket: String) async throws -> String {
            let comments = await tracker.costComments(ticket)
            try #require(comments.count == 1, "\(ticket) must receive exactly one cost comment; got \(comments)")
            return try #require(comments.first)
        }

        func pair(parentCredits: Double = 0.5, firstCredits: Double = 1, secondCredits: Double = 2) async throws {
            _ = try await add("GH-860", kind: .composite)
            _ = try await add("GH-899", parent: "wn-GH-860")
            _ = try await add("GH-898", parent: "wn-GH-860")
            try await cost("GH-860", credits: parentCredits, role: .decomposer)
            try await cost("GH-899", credits: firstCredits)
            try await cost("GH-898", credits: secondCredits)
        }

        func deepTree() async throws {
            _ = try await add("GH-860", kind: .composite)
            _ = try await add("GH-899", parent: "wn-GH-860")
            _ = try await add("GH-861", parent: "wn-GH-860", kind: .composite)
            _ = try await add("GH-898", parent: "wn-GH-861")
            _ = try await add("GH-862", parent: "wn-GH-861", kind: .composite)
            _ = try await add("GH-897", parent: "wn-GH-862")
            _ = try await add("GH-896", parent: "wn-GH-862")
            _ = try await add("GH-863", parent: "wn-GH-860")
            _ = try await add("GH-999")
            try await cost("GH-860", credits: 1.25, role: .decomposer, outcome: "failed: try again")
            try await cost("GH-860", credits: 0.75, role: .decomposer)
            try await cost("GH-861", credits: 0.5, role: .decomposer)
            try await cost("GH-862", credits: 1.5, role: .decomposer)
            try await cost("GH-899", credits: 0.25, role: .testAuthor)
            try await cost("GH-899", credits: 0.75, outcome: "failed: retry")
            try await cost("GH-899", credits: 1.5)
            try await cost("GH-899", credits: 0.5, role: .verifier)
            try await cost("GH-898", credits: 2)
            try await cost("GH-897", credits: 0.4)
            try await cost("GH-897", credits: 0.6, role: .diagnoser)
            try await cost("GH-896", credits: 0)
            try await cost("GH-863", credits: 4)
            try await cost("GH-999", credits: 1_000)
            try await prove("GH-899", "GH-898", "GH-897", "GH-896", "GH-863", "GH-999")
        }
    }

    actor MemoryTracker: TrackerAdapter {
        nonisolated let contextRepository = "fixture/credits"
        private var tickets: [String: Ticket] = [:]
        private var posted: [String: [String]] = [:]

        func add(_ key: String, title: String) {
            tickets[key] = Ticket(key: key, title: title, description: "", acceptanceCriteria: [],
                                  createdBy: .human("Cost test owner"))
        }
        func comments(_ key: String) -> [String] { posted[key] ?? [] }
        func costComments(_ key: String) -> [String] { comments(key).filter { $0.contains("AI credits") } }
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { tickets[key] }
        func contextTickets() async -> [Ticket] { Array(tickets.values) }
        func consume(_ signal: Signal, reply: String) async { comment(on: signal.ticket, reply) }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("GH-86 fixtures already have their breakdown")
        }
        func comment(on key: String, _ text: String) {
            posted[key, default: []].append(text)
            tickets[key]?.comments.append(Comment(author: .reconciler, text: text))
        }
        func setStatus(of key: String, to status: String) async { tickets[key]?.status = status }
    }

    struct NoWorkWorkspace: Workspace {
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "fixture/\(id)" }
        func worktree(for id: NodeID) -> URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: id)
        }
        func createWorktree(for id: NodeID) async throws -> URL {
            throw AgentFailure("GH-86 cost reporting must not create a worktree")
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("GH-86 cost reporting must not commit code")
        }
        func head(of directory: URL) async throws -> String { "fixture-main" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            throw AgentFailure("GH-86 cost reporting must not rebase code")
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("GH-86 fixture leaves are already proven")
        }
        func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
    }

    struct UnusedAgents: Decomposer, TestAuthor, Implementer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH-86 fixtures already have their breakdown")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-86 fixtures must not author tests")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-86 fixtures must not implement code")
        }
    }

    struct UnusedChecks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("GH-86 fixtures must not execute checks")
            return CheckOutput(passed: false, summary: "Unexpected check", log: "")
        }
    }

    struct MemoryArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }
}
