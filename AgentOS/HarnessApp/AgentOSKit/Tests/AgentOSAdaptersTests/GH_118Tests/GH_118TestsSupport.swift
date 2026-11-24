import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
@testable import AgentOSUI
import Foundation
import SwiftUI
import Testing

extension GH_118Tests {
    static let reason = "from someone without write access"
    static let instant = Date(timeIntervalSince1970: 1_780_401_600)

    static func comment(author: String, access: CommentWriteAccess, day: Int) -> AgentOSCore.Comment {
        var comment = AgentOSCore.Comment(author: .human(author), text: "Comment from \(author)")
        comment.at = instant.addingTimeInterval(Double(day) * 86_400)
        comment.writeAccess = access
        return comment
    }

    static func replacingText(of comment: AgentOSCore.Comment, with text: String) -> AgentOSCore.Comment {
        var edited = AgentOSCore.Comment(author: comment.author, text: text)
        edited.id = comment.id
        edited.at = comment.at
        edited.writeAccess = comment.writeAccess
        return edited
    }

    static func ticket(comments: [AgentOSCore.Comment]) -> Ticket {
        var ticket = Ticket(key: "GH-118", title: "Comment visibility", description: "Record ignored discussion",
                            acceptanceCriteria: ["Show ignored comments"], createdBy: .human("maintainer"))
        ticket.comments = comments
        return ticket
    }

    @MainActor
    static func detailLines(_ ticket: Ticket) throws -> [String] {
        let model = HarnessViewModel()
        model.tickets = [ticket]
        return try RenderedUI.text(in: RenderedUI.image(
            of: TicketDetail(ticket: ticket, edit: {}).environment(model),
            size: CGSize(width: 1_100, height: 850)))
    }

    @MainActor
    static func ledgerLines(_ ledger: Ledger) async throws -> [String] {
        let model = HarnessViewModel()
        await model.refreshLedger(from: ledger)
        return try RenderedUI.text(in: RenderedUI.image(
            of: LedgerPane().environment(model), size: CGSize(width: 1_200, height: 750)))
    }

    @MainActor
    static func ignoredNoticeCount(_ lines: [String]) -> Int {
        lines.filter { RenderedUI.shows("Ignored: \(reason)", in: $0) }.count
    }

    @MainActor
    static func showsDate(_ date: Date, in text: String) -> Bool {
        let styles: [Date.FormatStyle.DateStyle] = [.numeric, .abbreviated, .long, .complete]
        return styles.contains { RenderedUI.shows(date.formatted(date: $0, time: .omitted), in: text) }
    }

    struct IgnoredObservation: Sendable {
        let ticket: String
        let commentID: UUID
        let author: Participant
    }

    static func ignoredEvents(in ledger: Ledger) async -> [IgnoredObservation] {
        await ledger.allRecords().compactMap { record in
            guard case .commentIgnored(let ticket, let commentID, let author) = record.event.kind else { return nil }
            return IgnoredObservation(ticket: ticket, commentID: commentID, author: author)
        }
    }

    static func expectIgnored(_ comments: [AgentOSCore.Comment], in ledger: Ledger) async {
        let observations = await ignoredEvents(in: ledger)
        #expect(observations.count == comments.count, "Record each denied comment once, and no trusted/unknown ones.")
        for comment in comments {
            let matches = observations.filter { $0.ticket == "GH-118" && $0.commentID == comment.id }
            #expect(matches.count == 1, "\(comment.author.label), comment \(comment.id), must occur exactly once.")
            #expect(matches.allSatisfy { $0.author == comment.author }, "Keep the actual comment author.")
        }
    }

    static func round(_ reconciler: Reconciler) async throws {
        try await withHangGuard("GH-118 reconciler round") {
            let report = await reconciler.runRound(waitForAgents: true)
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
            #expect(!report.hasRunningAgents, "These fixtures have no open work gates.")
        }
    }

    static func fixture(adopted: Bool, comments: [AgentOSCore.Comment]) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "GH-118-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledgerFile = directory.appending(path: "ledger.jsonl")
        let ledger = try Ledger(store: FileLedgerStore(fileURL: ledgerFile))
        var ticket = Self.ticket(comments: comments)
        if adopted {
            let spec = Planner.rootSpec(for: ticket)
            try await ledger.append([LedgerEvent(node: spec.id, by: .human("maintainer"),
                                                 kind: .nodeCreated(spec: spec, ticket: ticket.key))])
            let state = await ledger.workingState()
            let node = try #require(state.node(forTicket: ticket.key))
            ticket.status = state.status(of: node)
        } else {
            ticket.labels = [LabelMark(name: HarnessCommand.retry.label, setBy: .human("maintainer"))]
        }
        return Fixture(directory: directory, ledgerFile: ledgerFile, ledger: ledger, tracker: TrackerSpy(ticket))
    }

    static func removeFiles(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Could not clean up GH-118 fixture: \(error)") }
    }

    struct Fixture: Sendable {
        let directory: URL
        let ledgerFile: URL
        let ledger: Ledger
        let tracker: TrackerSpy

        func reconciler(ledger replacement: Ledger? = nil, tracker replacementTracker: (any TrackerAdapter)? = nil) -> Reconciler {
            let agents = NoWorkAgents()
            return Reconciler(ledger: replacement ?? ledger, tracker: replacementTracker ?? tracker, external: NoExternal(),
                              workspace: NoWorkWorkspace(root: directory), artifacts: NoArtifacts(),
                              checks: NoChecks(), team: AgentTeam(
                                name: "GH-118 observer", decomposer: agents, testAuthor: agents, implementer: agents),
                              now: { GH_118Tests.instant })
        }
    }

    actor GitHubPermissionFailureTransport: GitHubTransport {
        let status: String
        private(set) var failedPermissionReads = 0

        init(status: String) { self.status = status }

        func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
            let route = String(path.split(separator: "?")[0])
            func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
            if method == "GET", route == "user" {
                return try json(["login": "harness-user", "type": "User"])
            }
            if method == "GET", route == "repos/acme/app/collaborators/lookup-unavailable/permission" {
                failedPermissionReads += 1
                throw AgentFailure("HTTP 429: permission lookup unavailable")
            }
            if method == "GET", route == "repos/acme/app/collaborators/outside-reader/permission" {
                return try json(["permission": "read"])
            }
            if method == "GET", route == "repos/acme/app/issues" || route == "repos/acme/app/issues/118" {
                let issue: [String: Any] = [
                    "id": 1118, "number": 118, "title": "Comment visibility",
                    "body": "Record ignored discussion\n\n## Acceptance criteria\n- Show ignored comments",
                    "state": "open", "user": ["login": "maintainer", "type": "User"],
                    "labels": [["name": GitHubIssuesTracker.statusPrefix + status]],
                    "updated_at": "2026-06-01T00:00:00Z",
                ]
                return try json(route.hasSuffix("/118") ? issue : [issue])
            }
            if method == "GET", route == "repos/acme/app/issues/118/comments" {
                return try json([
                    ["id": 501, "body": "Permission lookup failed",
                     "user": ["login": "lookup-unavailable", "type": "User"],
                     "created_at": "2026-06-01T00:00:00Z"],
                    ["id": 502, "body": "Confirmed read-only commenter",
                     "user": ["login": "outside-reader", "type": "User"],
                     "created_at": "2026-06-02T00:00:00Z"],
                ])
            }
            if method == "POST", route == "repos/acme/app/labels" { return try json([:]) }
            throw AgentFailure("Unexpected GH-118 fixture request: \(method) \(path)")
        }
    }

    actor TrackerSpy: TrackerAdapter {
        enum Mutation: Sendable, Hashable {
            case comment(String, String)
            case labelRemoved(String, String)
            case status(String, String)
            case childCreated(String)
        }
        private var current: Ticket
        private(set) var mutations: [Mutation] = []

        init(_ ticket: Ticket) { current = ticket }
        func snapshot() -> Ticket { current }
        func replaceComments(_ comments: [AgentOSCore.Comment]) { current.comments = comments }
        func addSignal(_ command: HarnessCommand) {
            current.labels.append(LabelMark(name: command.label, setBy: .human("maintainer")))
        }
        func ticket(_ key: String) -> Ticket? { key == current.key ? current : nil }
        func contextTickets() -> [Ticket] { [current] }
        func pendingSignals() -> [Signal] {
            current.labels.compactMap { label in
                guard let command = HarnessCommand.allCases.first(where: { $0.label == label.name }) else { return nil }
                return Signal(ticket: current.key, command: command, setBy: label.setBy)
            }
        }
        func consume(_ signal: Signal, reply: String) {
            guard signal.ticket == current.key else {
                Issue.record("Unexpected tracker key \(signal.ticket)")
                return
            }
            if current.labels.contains(where: { $0.name == signal.command.label }) {
                current.labels.removeAll { $0.name == signal.command.label }
                mutations.append(.labelRemoved(signal.ticket, signal.command.label))
            }
            comment(on: signal.ticket, reply)
        }
        func comment(on key: String, _ text: String) {
            guard key == current.key else {
                Issue.record("Unexpected tracker key \(key)")
                return
            }
            mutations.append(.comment(key, text))
            current.comments.append(AgentOSCore.Comment(author: .reconciler, text: text))
        }
        func setStatus(of key: String, to status: String) {
            guard key == current.key else {
                Issue.record("Unexpected tracker key \(key)")
                return
            }
            guard current.status != status else { return }
            mutations.append(.status(key, status))
            current.status = status
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            mutations.append(.childCreated(parent))
            throw AgentFailure("An observation-only fixture must not create child tickets")
        }
    }

    struct NoExternal: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    struct NoWorkAgents: Decomposer, TestAuthor, Implementer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("Comment observation must not start decomposition")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Comment observation must not start test authoring")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Comment observation must not start implementation")
        }
    }

    struct NoArtifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            throw AgentFailure("Comment observation must not write artifacts")
        }
    }

    struct NoChecks: CheckRunner {
        func runChecks(in directory: URL, only suite: String?) async -> CheckOutput {
            Issue.record("Comment observation unexpectedly ran checks")
            return CheckOutput(passed: false, summary: "Unexpected check", log: "")
        }
    }

    struct NoWorkWorkspace: Workspace {
        let root: URL
        var testArea: String { "Tests/" }
        var agentContext: String { "" }
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { root.appending(path: id) }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        func existingComponents() -> [String] { [] }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        func head(of directory: URL) async throws -> String { "observation-only-head" }
        func prepareBuild(in directory: URL) async throws {}
        func removeWorktree(for id: NodeID) async throws {}
        func abortRebase(_ directory: URL) async throws {}
        func createWorktree(for id: NodeID) async throws -> URL {
            throw AgentFailure("Comment observation must not create worktrees")
        }
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Comment observation must not commit")
        }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            throw AgentFailure("Comment observation must not rebase")
        }
        func resetForRework(_ directory: URL) async throws {
            throw AgentFailure("Comment observation must not reset work")
        }
        func landOnMain(_ id: NodeID) async throws -> String {
            throw AgentFailure("Comment observation must not land work")
        }
    }
}
