import AgentOSCore
import Foundation

/// GitHub's REST API, one request at a time. Paths are relative to the API root, e.g. `repos/o/r/issues`.
public protocol GitHubTransport: Sendable {
    /// The response body; throws for any HTTP error.
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data
}

public struct GitHubError: Error, CustomStringConvertible {
    public let description: String
}

/// Talks to GitHub through the GitHub CLI (`gh api`), so it uses the login you already have. With an
/// `account`, that account's token is used for the harness's own requests only; agents never get it.
public struct GhCLITransport: GitHubTransport {
    public let executable: String
    public let account: String?
    private let token = TokenCache()

    public init(executable: String, account: String? = nil) {
        self.executable = executable
        self.account = account
    }

    public static func locate() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        var arguments = ["api", "--method", method, path, "-H", "Accept: application/vnd.github+json"]
        var input: URL?
        if let body {
            let file = FileManager.default.temporaryDirectory.appending(path: "agentos-gh-\(UUID().uuidString).json")
            try body.write(to: file)
            arguments += ["--input", file.path]
            input = file
        }
        defer { if let input { try? FileManager.default.removeItem(at: input) } }
        let result = try await ProcessRunner.run(executable, arguments, in: FileManager.default.temporaryDirectory,
                                                 timeout: .seconds(60), environment: try await environment())
        guard result.status == 0 else {
            throw GitHubError(description: "\(method) \(path) failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))")
        }
        return Data(result.output.utf8)
    }

    private func environment() async throws -> [String: String] {
        guard let account else { return [:] }
        if let cached = await token.value { return ["GH_TOKEN": cached] }
        let result = try await ProcessRunner.run(executable, ["auth", "token", "--user", account],
                                                 in: FileManager.default.temporaryDirectory, timeout: .seconds(30))
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !value.isEmpty, !value.contains(" ") else {
            throw GitHubError(description: "No GitHub CLI login for \(account). Run `gh auth login` as \(account).")
        }
        await token.set(value)
        return ["GH_TOKEN": value]
    }

    private actor TokenCache {
        var value: String?
        func set(_ value: String) { self.value = value }
    }
}

/// GitHub Issues as the repo's tracker (doc 03). Issues are tickets keyed `GH-<number>`; pull requests are
/// left out. Labels are the signals, as in the local tracker: who set one comes from the issue's events.
///
/// The harness acts as your `gh` login, so its comments and issues carry a hidden marker (`<!-- agentos -->`)
/// to tell them apart from yours. Statuses are `agentos: <status>` labels. Acceptance criteria are the list
/// under an "Acceptance criteria" heading in the issue body; a `Blocked by:` line names what other systems
/// must deliver.
///
/// Requests are kept few: open issues are listed at most every `listInterval` (and after the harness's own
/// changes), comments and label events are fetched again only when the issue changed. Production: webhooks
/// plus polling, with ETags and rate-limit handling.
public actor GitHubIssuesTracker: TrackerAdapter, TicketBoard {
    public nonisolated let repo: String
    private let transport: any GitHubTransport
    private let listInterval: Duration
    /// The board whose status field shows the harness's status, if the config names one.
    private let board: GitHubProjectBoard?

    private var openIssues: [Issue] = []
    private var listedAt: ContinuousClock.Instant?
    private var commentCache: [Int: (updatedAt: String, comments: [Comment])] = [:]
    private var labelSetters: [String: Participant] = [:]
    /// Statuses the harness set: the listed labels can be older.
    private var statuses: [Int: String] = [:]
    private var labelsCreated = false
    private var problems: [String] = []

    public static let keyPrefix = "GH-"
    public static let marker = "<!-- agentos -->"
    public static let statusPrefix = "agentos: "

    public init(repo: String, transport: any GitHubTransport, project: RepoConfig.Tracker.Project? = nil,
                listInterval: Duration = .seconds(10)) {
        self.repo = repo
        self.transport = transport
        self.listInterval = listInterval
        board = project.map { GitHubProjectBoard(config: $0, repo: repo, transport: transport) }
    }

    public nonisolated var name: String { "GitHub Issues: \(repo)" + (board.map { ", board \($0.name)" } ?? "") }
    public nonisolated var adapter: any TrackerAdapter { self }

    /// `owner/name` from a GitHub remote URL (`git@github.com:o/r.git`, `https://github.com/o/r`), else nil.
    public static func repo(fromRemote url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: Substring
        if let range = trimmed.range(of: "github.com:") ?? trimmed.range(of: "github.com/") {
            path = trimmed[range.upperBound...]
        } else {
            return nil
        }
        let parts = path.split(separator: "/").map { String($0) }
        guard parts.count == 2 else { return nil }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return parts[0].isEmpty || name.isEmpty ? nil : "\(parts[0])/\(name)"
    }

    // MARK: TrackerAdapter

    public func pendingSignals() async -> [Signal] {
        await createHarnessLabels()
        var signals: [Signal] = []
        for issue in await listOpenIssues() {
            for label in issue.labels {
                guard let command = HarnessCommand.allCases.first(where: { $0.label == label.name }) else { continue }
                signals.append(Signal(ticket: Self.key(issue.number), command: command, setBy: await setter(of: label.name, on: issue)))
            }
        }
        return signals
    }

    public func ticket(_ key: String) async -> Ticket? {
        guard let number = Self.number(key) else { return nil }
        let listed = await listOpenIssues().first { $0.number == number }
        let found: Issue?
        if let listed { found = listed } else { found = await attempt("Reading \(key)") { try await self.get(Issue.self, "repos/\(self.repo)/issues/\(number)") } }
        guard let issue = found, issue.pullRequest == nil else { return nil }
        return await ticket(from: issue)
    }

    public func consume(_ signal: Signal, reply: String) async {
        guard let number = Self.number(signal.ticket) else { return }
        await removeLabel(signal.command.label, from: number)
        await post(comment: reply, on: number, byHarness: true)
    }

    public func createChildTicket(parent: String, spec: NodeSpec, by who: Participant) async throws -> String {
        let body = Self.body(description: spec.intent, criteria: spec.acceptanceCriteria, blockedBy: spec.dependsOn,
                             parent: Self.number(parent), summary: spec.trackerSummary, byHarness: true)
        let created = try await send(Issue.self, "POST", "repos/\(repo)/issues", ["title": spec.title, "body": body])
        // GitHub's own parent link, where sub-issues are available; the body's "Parent:" line is what counts.
        if let parentNumber = Self.number(parent) {
            _ = try? await transport.request("POST", "repos/\(repo)/issues/\(parentNumber)/sub_issues",
                                             body: try JSONSerialization.data(withJSONObject: ["sub_issue_id": created.id]))
        }
        listedAt = nil
        return Self.key(created.number)
    }

    public func comment(on key: String, _ text: String) async {
        guard let number = Self.number(key) else { return }
        await post(comment: text, on: number, byHarness: true)
    }

    /// On the board when the config names one and it has an option for the status; otherwise an `agentos:`
    /// label. Written only when it changes (the reconciler sets every status each round).
    public func setStatus(of key: String, to status: String) async {
        guard let number = Self.number(key), statuses[number] != status else { return }
        var labels = (await listOpenIssues()).first { $0.number == number }?.labels.map(\.name)
        if labels == nil {
            labels = await attempt("Reading \(key)") { try await self.get(Issue.self, "repos/\(self.repo)/issues/\(number)") }?
                .labels.map(\.name)
        }
        let statusLabels = (labels ?? []).filter { $0.hasPrefix(Self.statusPrefix) }
        if let board, await attempt("Reading the board \(board.name)", { try await board.shows(status) }) == true {
            guard await attempt("Moving \(key) to \(status) on the board", { try await board.set(issue: number, to: status) }) != nil
            else { return }
            for old in statusLabels { await removeLabel(old, from: number) }
            statuses[number] = status
            return
        }
        let wanted = Self.statusPrefix + status
        for old in statusLabels where old != wanted { await removeLabel(old, from: number) }
        if !statusLabels.contains(wanted) {
            let added: Data? = await attempt("Setting the status of \(key)") {
                try await self.transport.request("POST", "repos/\(self.repo)/issues/\(number)/labels",
                                                  body: try JSONSerialization.data(withJSONObject: ["labels": [wanted]]))
            }
            guard added != nil else { return }
            listedAt = nil
        }
        statuses[number] = status
    }

    // MARK: TicketBoard (what people do through the app)

    public func tickets() async -> [Ticket] {
        var result: [Ticket] = []
        for issue in await listOpenIssues() { result.append(await ticket(from: issue)) }
        return result
    }

    public func addLabel(_ name: String, to key: String, by who: Participant) async {
        guard let number = Self.number(key) else { return }
        _ = await attempt("Adding \(name) to \(key)") {
            try await self.transport.request("POST", "repos/\(self.repo)/issues/\(number)/labels",
                                             body: try JSONSerialization.data(withJSONObject: ["labels": [name]]))
        }
        listedAt = nil
    }

    public func removeLabel(_ name: String, from key: String) async {
        guard let number = Self.number(key) else { return }
        await removeLabel(name, from: number)
    }

    public func addComment(_ text: String, to key: String, by who: Participant) async {
        guard let number = Self.number(key) else { return }
        await post(comment: text, on: number, byHarness: !who.isHuman)
    }

    public func newTicket(title: String, description: String, acceptanceCriteria: [String], blockedBy: [String],
                          by author: Participant) async -> Ticket? {
        let body = Self.body(description: description, criteria: acceptanceCriteria, blockedBy: blockedBy, parent: nil,
                             summary: nil, byHarness: !author.isHuman)
        guard let issue = await attempt("Creating \"\(title)\"", {
            try await self.send(Issue.self, "POST", "repos/\(self.repo)/issues", ["title": title, "body": body])
        }) else { return nil }
        listedAt = nil
        return await ticket(from: issue)
    }

    public func edit(_ key: String, title: String, description: String, acceptanceCriteria: [String], blockedBy: [String]) async {
        guard let number = Self.number(key), let current = await ticket(key) else { return }
        let parsed = Self.parse(body: openIssues.first { $0.number == number }?.body ?? "")
        let body = Self.body(description: description, criteria: acceptanceCriteria, blockedBy: blockedBy,
                             parent: current.parentKey.flatMap(Self.number), summary: parsed.summary, byHarness: parsed.byHarness)
        _ = await attempt("Editing \(key)") {
            try await self.send(Issue.self, "PATCH", "repos/\(self.repo)/issues/\(number)", ["title": title, "body": body])
        }
        listedAt = nil
    }

    public func takeProblems() -> [String] {
        defer { problems.removeAll() }
        return problems
    }

    // MARK: Issue bodies

    /// The issue body the harness writes: description, acceptance criteria as a task list, then the links.
    static func body(description: String, criteria: [String], blockedBy: [String], parent: Int?, summary: String?,
                     byHarness: Bool) -> String {
        var parts = [description.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !criteria.isEmpty { parts.append("## Acceptance criteria\n" + criteria.map { "- [ ] \($0)" }.joined(separator: "\n")) }
        var links: [String] = []
        if !blockedBy.isEmpty { links.append("Blocked by: \(blockedBy.joined(separator: ", "))") }
        if let parent { links.append("Parent: #\(parent)") }
        if let summary { links.append(summary) }
        if !links.isEmpty { parts.append(links.joined(separator: "\n")) }
        if byHarness { parts.append(marker) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    struct ParsedBody: Equatable {
        var description: String
        var criteria: [String]
        var blockedBy: [String]
        var parent: Int?
        /// The harness's "Work node: …" line on issues it created.
        var summary: String?
        var byHarness: Bool
    }

    /// Reads what `body(...)` writes, and what people write by hand: an "Acceptance criteria" heading (or a line
    /// "Acceptance criteria:") followed by a bulleted, numbered or task list.
    static func parse(body: String) -> ParsedBody {
        var result = ParsedBody(description: "", criteria: [], blockedBy: [], parent: nil, summary: nil, byHarness: false)
        var kept: [String] = []
        var inCriteria = false
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            let lower = text.lowercased()
            if text == marker { result.byHarness = true; continue }
            if text.hasPrefix("Work node: ") { result.summary = text; continue }
            if lower.hasPrefix("blocked by:") {
                result.blockedBy = text.dropFirst("blocked by:".count).split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                continue
            }
            if lower.hasPrefix("parent:"), let number = Int(text.dropFirst("parent:".count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))) {
                result.parent = number
                continue
            }
            let heading = lower.trimmingCharacters(in: CharacterSet(charactersIn: "#*_: "))
            if heading == "acceptance criteria" && (text.hasPrefix("#") || text.hasSuffix(":") || text.hasPrefix("**")) {
                inCriteria = true
                continue
            }
            if inCriteria {
                if text.isEmpty { continue }
                if let item = listItem(text) {
                    result.criteria.append(item)
                    continue
                }
                inCriteria = false
            }
            kept.append(String(line))
        }
        result.description = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        return result
    }

    /// The text of a list item (`- x`, `* x`, `1. x`, `- [ ] x`), or nil.
    private static func listItem(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.+)$/) else { return nil }
        return String(match.output.1).trimmingCharacters(in: .whitespaces)
    }

    static func key(_ number: Int) -> String { "\(keyPrefix)\(number)" }

    static func number(_ key: String) -> Int? {
        key.hasPrefix(keyPrefix) ? Int(key.dropFirst(keyPrefix.count)) : nil
    }

    // MARK: Reading

    private func listOpenIssues() async -> [Issue] {
        if let listedAt, ContinuousClock.now - listedAt < listInterval { return openIssues }
        if let issues = await attempt("Listing issues in \(repo)", { try await self.all(Issue.self, "repos/\(self.repo)/issues?state=open") }) {
            openIssues = issues.filter { $0.pullRequest == nil }
            listedAt = .now
        }
        return openIssues
    }

    private func ticket(from issue: Issue) async -> Ticket {
        let parsed = Self.parse(body: issue.body ?? "")
        var ticket = Ticket(
            key: Self.key(issue.number), title: issue.title, description: parsed.description,
            acceptanceCriteria: parsed.criteria, blockedBy: parsed.blockedBy, parentKey: parsed.parent.map(Self.key),
            createdBy: parsed.byHarness ? .reconciler : Self.participant(issue.user))
        var labels: [LabelMark] = []
        for label in issue.labels where !label.name.hasPrefix(Self.statusPrefix) {
            let isSignal = HarnessCommand.allCases.contains { $0.label == label.name }
            labels.append(LabelMark(name: label.name, setBy: isSignal ? await setter(of: label.name, on: issue) : .adapter("GitHub")))
        }
        ticket.labels = labels
        ticket.status = statuses[issue.number]
            ?? issue.labels.first { $0.name.hasPrefix(Self.statusPrefix) }.map { String($0.name.dropFirst(Self.statusPrefix.count)) }
            ?? (issue.state == "closed" ? "Done" : "To Do")
        ticket.comments = await comments(of: issue)
        return ticket
    }

    private func comments(of issue: Issue) async -> [Comment] {
        if let cached = commentCache[issue.number], cached.updatedAt == issue.updatedAt { return cached.comments }
        guard let fetched = await attempt("Reading comments on \(Self.key(issue.number))", {
            try await self.all(IssueComment.self, "repos/\(self.repo)/issues/\(issue.number)/comments")
        }) else { return commentCache[issue.number]?.comments ?? [] }
        let comments = fetched.map { item in
            let text = item.body ?? ""
            let byHarness = text.contains(Self.marker)
            var comment = Comment(author: byHarness ? .reconciler : Self.participant(item.user),
                                  text: text.replacingOccurrences(of: Self.marker, with: "").trimmingCharacters(in: .whitespacesAndNewlines))
            comment.id = Self.uuid(item.id)
            comment.at = Self.date(item.createdAt) ?? comment.at
            return comment
        }
        commentCache[issue.number] = (issue.updatedAt, comments)
        return comments
    }

    /// Who added the label last, from the issue's events. Anyone not known as a person counts as a tool.
    private func setter(of label: String, on issue: Issue) async -> Participant {
        let cacheKey = "\(issue.number)|\(label)|\(issue.updatedAt)"
        if let known = labelSetters[cacheKey] { return known }
        guard let events = await attempt("Reading events of \(Self.key(issue.number))", {
            try await self.all(IssueEvent.self, "repos/\(self.repo)/issues/\(issue.number)/events")
        }) else { return .adapter("GitHub") }
        let actor = events.last { $0.event == "labeled" && $0.label?.name == label }?.actor
        let setter = actor.map(Self.participant) ?? .adapter("GitHub")
        labelSetters[cacheKey] = setter
        return setter
    }

    static func participant(_ user: User) -> Participant {
        user.type == "Bot" || user.login.hasSuffix("[bot]") ? .adapter(user.login) : .human(user.login)
    }

    // MARK: Writing

    private func post(comment text: String, on number: Int, byHarness: Bool) async {
        let body = byHarness ? text + "\n\n" + Self.marker : text
        _ = await attempt("Commenting on \(Self.key(number))") {
            try await self.transport.request("POST", "repos/\(self.repo)/issues/\(number)/comments",
                                             body: try JSONSerialization.data(withJSONObject: ["body": body]))
        }
        listedAt = nil
    }

    private func removeLabel(_ name: String, from number: Int) async {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? name
        _ = await attempt("Removing \(name) from \(Self.key(number))") {
            try await self.transport.request("DELETE", "repos/\(self.repo)/issues/\(number)/labels/\(encoded)", body: nil)
        }
        listedAt = nil
    }

    /// People can only add a label that exists in the repo: create the signals once (existing ones are kept).
    private func createHarnessLabels() async {
        guard !labelsCreated else { return }
        labelsCreated = true
        for command in HarnessCommand.allCases {
            let label: [String: String] = ["name": command.label, "color": "5319e7", "description": "AgentOS: ask the harness to \(command.rawValue)"]
            _ = try? await transport.request("POST", "repos/\(repo)/labels", body: try JSONSerialization.data(withJSONObject: label))
        }
    }

    // MARK: Requests

    private func attempt<T>(_ what: String, _ operation: () async throws -> T) async -> T? {
        do { return try await operation() } catch {
            problems.append("\(what): \(error)")
            return nil
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        try Self.decoder.decode(T.self, from: try await transport.request("GET", path, body: nil))
    }

    private func send<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, _ body: [String: Any]) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try Self.decoder.decode(T.self, from: try await transport.request(method, path, body: data))
    }

    /// Every page (`--paginate` would concatenate the JSON arrays).
    private func all<T: Decodable>(_ type: T.Type, _ path: String) async throws -> [T] {
        var result: [T] = []
        let separator = path.contains("?") ? "&" : "?"
        for page in 1...20 {
            let items = try await get([T].self, "\(path)\(separator)per_page=100&page=\(page)")
            result += items
            if items.count < 100 { break }
        }
        return result
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static func date(_ text: String) -> Date? { try? Date(text, strategy: .iso8601) }

    /// A stable id for a GitHub comment, so the app keeps track of it between reloads.
    private static func uuid(_ id: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", UInt64(truncatingIfNeeded: id))) ?? UUID()
    }

    struct User: Decodable, Sendable {
        let login: String
        let type: String?
    }

    struct Label: Decodable, Sendable {
        let name: String
    }

    struct PullRequestLink: Decodable, Sendable {}

    struct Issue: Decodable, Sendable {
        let id: Int
        let number: Int
        let title: String
        let body: String?
        let state: String
        let labels: [Label]
        let user: User
        let updatedAt: String
        let pullRequest: PullRequestLink?
    }

    struct IssueComment: Decodable, Sendable {
        let id: Int
        let body: String?
        let user: User
        let createdAt: String
    }

    struct IssueEvent: Decodable, Sendable {
        let event: String
        let actor: User?
        let label: Label?
    }
}
