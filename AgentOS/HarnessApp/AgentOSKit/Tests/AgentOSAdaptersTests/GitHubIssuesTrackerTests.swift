@testable import AgentOSAdapters
@testable import AgentOSCore
import Foundation
import Testing

/// GitHub's API as far as the tracker uses it, in memory.
private actor FakeGitHub: GitHubTransport {
    struct Request: Equatable { let method: String; let path: String; let body: String? }

    var issues: [[String: Any]] = []
    var comments: [Int: [[String: Any]]] = [:]
    var events: [Int: [[String: Any]]] = [:]
    var requests: [Request] = []
    var failCreating = false
    /// The board: its options, each issue's card (option name), and the cards moved.
    var boardOptions = ["Backlog", "Ready", "In progress", "In review", "Done"]
    var boardError: String?
    var cards: [Int: String?] = [:]
    var moves: [String] = []

    func add(issue number: Int, title: String = "Title", body: String, labels: [String] = [], by login: String = "alice") {
        issues.append(["id": 1000 + number, "number": number, "title": title, "body": body, "state": "open",
                       "labels": labels.map { ["name": $0] }, "user": ["login": login, "type": "User"],
                       "updated_at": "2025-01-01T00:00:00Z"])
    }

    func addPullRequest(_ number: Int, label: String) {
        add(issue: number, body: "A pull request", labels: [label])
        update(number) { $0["pull_request"] = ["url": "https://example.com"] }
    }

    func label(_ number: Int, _ name: String, by login: String, type: String = "User") {
        events[number, default: []].append(["event": "labeled", "actor": ["login": login, "type": type], "label": ["name": name]])
        update(number) { issue in
            issue["labels"] = (issue["labels"] as! [[String: String]]) + [["name": name]]
        }
    }

    func comment(_ number: Int, _ body: String, by login: String) {
        let id = 500 + (comments[number]?.count ?? 0)
        comments[number, default: []].append(["id": id, "body": body, "user": ["login": login, "type": "User"],
                                              "created_at": "2025-01-02T00:00:00Z"])
        update(number) { $0["updated_at"] = "2025-01-02T00:00:0\(id % 10)Z" }
    }

    func setFailCreating(_ value: Bool) { failCreating = value }
    func setBoard(options: [String]? = nil, error: String? = nil) {
        if let options { boardOptions = options }
        boardError = error
    }
    func putOnBoard(_ number: Int, at option: String?) { cards[number] = option }

    private func graphql(_ query: String, _ variables: [String: Any]) -> Any {
        if query.contains("repositoryOwner") {
            if let boardError { return ["errors": [["message": boardError]]] }
            let options = boardOptions.map { ["id": "opt-\($0)", "name": $0] }
            let project: [String: Any] = ["id": "PVT_1", "title": "Roadmap", "field": ["id": "FIELD_1", "options": options]]
            return ["data": ["repositoryOwner": ["projectV2": project]]]
        }
        if query.contains("updateProjectV2ItemFieldValue") {
            let option = String((variables["option"] as! String).dropFirst(4))
            let number = Int((variables["item"] as! String).dropFirst(5))!
            cards[number] = option
            moves.append("#\(number) → \(option)")
            return ["data": ["updateProjectV2ItemFieldValue": ["projectV2Item": ["id": variables["item"]!]]]]
        }
        if query.contains("addProjectV2ItemById") {
            let number = Int((variables["content"] as! String).dropFirst(2))!
            cards[number] = .some(nil)
            return ["data": ["addProjectV2ItemById": ["item": ["id": "CARD_\(number)"]]]]
        }
        let number = variables["number"] as! Int
        let nodes: [[String: Any]] = cards[number].map { option in
            [["id": "CARD_\(number)", "project": ["id": "PVT_1"], "fieldValueByName": option.map { ["name": $0] } as Any]]
        } ?? []
        return ["data": ["repository": ["issue": ["id": "I_\(number)", "projectItems": ["nodes": nodes]]]]]
    }
    func paths(_ method: String) -> [String] { requests.filter { $0.method == method }.map(\.path) }
    func bodies(_ method: String, _ path: String) -> [String] {
        requests.filter { $0.method == method && $0.path == path }.compactMap(\.body)
    }

    private func update(_ number: Int, _ change: (inout [String: Any]) -> Void) {
        guard let index = issues.firstIndex(where: { $0["number"] as? Int == number }) else { return }
        change(&issues[index])
    }

    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        requests.append(Request(method: method, path: path, body: body.map { String(decoding: $0, as: UTF8.self) }))
        let route = path.split(separator: "?").first.map(String.init) ?? path
        let parts = route.split(separator: "/").map(String.init)
        let page = path.contains("page=1") || !path.contains("page=")
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        let sent = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        if path == "graphql" {
            return try json(graphql(sent["query"] as! String, sent["variables"] as! [String: Any]))
        }
        switch (method, parts.count, parts.last) {
        case ("GET", 4, "issues"): return try json(page ? issues : [])
        case ("GET", 6, "comments"): return try json(page ? comments[Int(parts[4])!] ?? [] : [])
        case ("GET", 6, "events"): return try json(page ? events[Int(parts[4])!] ?? [] : [])
        case ("GET", 5, _): return try json(issues.first { $0["number"] as? Int == Int(parts[4]) } ?? [:])
        case ("POST", 4, "issues"):
            if failCreating { throw GitHubError(description: "HTTP 403") }
            let number = (issues.compactMap { $0["number"] as? Int }.max() ?? 0) + 1
            add(issue: number, title: sent["title"] as! String, body: sent["body"] as! String, by: "harness-user")
            return try json(issues.last!)
        case ("POST", 6, "comments"):
            comment(Int(parts[4])!, sent["body"] as! String, by: "harness-user")
            return try json([:])
        case ("POST", 6, "labels"):
            for name in sent["labels"] as! [String] { label(Int(parts[4])!, name, by: "harness-user") }
            return try json([])
        case ("DELETE", 7, _):
            let name = parts[6].removingPercentEncoding!
            update(Int(parts[4])!) { issue in
                issue["labels"] = (issue["labels"] as! [[String: String]]).filter { $0["name"] != name }
            }
            return try json([])
        default:
            return try json([:])
        }
    }
}

@Suite struct GitHubIssuesTrackerTests {
    private func tracker(_ github: FakeGitHub) -> GitHubIssuesTracker {
        GitHubIssuesTracker(repo: "o/r", transport: github, listInterval: .zero)
    }

    @Test func readsAHandWrittenIssueAsATicket() async {
        let github = FakeGitHub()
        await github.add(issue: 7, title: "Show totals", body: """
            Users want to see totals.

            **Acceptance criteria:**
            - [ ] The total shows below the list
            * It updates when an item changes
            1. Zero shows as "—"

            Blocked by: BACKEND-42, BACKEND-43
            Thanks!
            """)
        let ticket = await tracker(github).ticket("GH-7")
        #expect(ticket?.title == "Show totals")
        #expect(ticket?.acceptanceCriteria == ["The total shows below the list", "It updates when an item changes", "Zero shows as \"—\""])
        #expect(ticket?.blockedBy == ["BACKEND-42", "BACKEND-43"])
        #expect(ticket?.description == "Users want to see totals.\n\nThanks!")
        #expect(ticket?.createdBy == .human("alice"))
        #expect(ticket?.status == "To Do")
    }

    @Test func theBodyItWritesReadsBack() {
        let body = GitHubIssuesTracker.body(description: "Do it.", criteria: ["A", "B"], blockedBy: ["X-1"], parent: 3,
                                            summary: "Work node: wn-1.1 · kind: leaf", byHarness: true)
        let parsed = GitHubIssuesTracker.parse(body: body)
        #expect(parsed == .init(description: "Do it.", criteria: ["A", "B"], blockedBy: ["X-1"], parent: 3,
                                summary: "Work node: wn-1.1 · kind: leaf", byHarness: true))
    }

    @Test func signalsSayWhoSetTheLabelAndPullRequestsAreLeftOut() async {
        let github = FakeGitHub()
        await github.add(issue: 1, body: "x")
        await github.add(issue: 2, body: "y")
        await github.label(1, "harness:go", by: "alice")
        await github.label(2, "harness:build", by: "dependabot[bot]", type: "Bot")
        await github.label(2, "bug", by: "alice")
        await github.addPullRequest(3, label: "harness:go")
        let tracker = tracker(github)

        let signals = await tracker.pendingSignals()
        #expect(signals.map(\.ticket) == ["GH-1", "GH-2"])
        #expect(await tracker.ticket("GH-3") == nil)
        #expect(signals.map(\.setBy) == [.human("alice"), .adapter("dependabot[bot]")])
        let labels = await tracker.ticket("GH-2")?.labels
        #expect(labels == [LabelMark(name: "harness:build", setBy: .adapter("dependabot[bot]")), LabelMark(name: "bug", setBy: .adapter("GitHub"))])
    }

    @Test func consumingRemovesTheLabelAndRepliesAsTheHarness() async {
        let github = FakeGitHub()
        await github.add(issue: 1, body: "x")
        await github.label(1, "harness:go", by: "alice")
        await github.comment(1, "Please make it blue", by: "alice")
        let tracker = tracker(github)

        await tracker.consume(Signal(ticket: "GH-1", command: .go, setBy: .human("alice")), reply: "On it")
        #expect(await github.paths("DELETE") == ["repos/o/r/issues/1/labels/harness%3Ago"])
        #expect(await tracker.pendingSignals().isEmpty)
        let comments = await tracker.ticket("GH-1")?.comments ?? []
        #expect(comments.map(\.author) == [.human("alice"), .reconciler])
        #expect(comments.map(\.text) == ["Please make it blue", "On it"])
        #expect(comments.first?.id == UUID(uuidString: "00000000-0000-0000-0000-0000000001F4"))
    }

    @Test func statusIsALabelChangedOnlyWhenItChanges() async {
        let github = FakeGitHub()
        await github.add(issue: 1, body: "x")
        let tracker = tracker(github)

        await tracker.setStatus(of: "GH-1", to: "In progress")
        await tracker.setStatus(of: "GH-1", to: "In progress")
        await tracker.setStatus(of: "GH-1", to: "Done")
        #expect(await github.bodies("POST", "repos/o/r/issues/1/labels") == [
            #"{"labels":["agentos: In progress"]}"#, #"{"labels":["agentos: Done"]}"#])
        #expect(await github.paths("DELETE") == ["repos/o/r/issues/1/labels/agentos%3A%20In%20progress"])
        let ticket = await tracker.ticket("GH-1")
        #expect(ticket?.status == "Done")
        #expect(ticket?.labels.isEmpty == true)
    }

    @Test func childIssuesLinkToTheirParentAndFailuresThrow() async throws {
        let github = FakeGitHub()
        await github.add(issue: 4, body: "parent")
        let tracker = tracker(github)
        var spec = NodeSpec(id: "wn-4.1", parent: "wn-4", kind: .leaf, title: "Child", intent: "Part one.",
                            acceptanceCriteria: ["It works"])
        spec.dependsOn = ["API-9"]

        let key = try await tracker.createChildTicket(parent: "GH-4", spec: spec, by: .reconciler)
        #expect(key == "GH-5")
        let child = await tracker.ticket("GH-5")
        #expect(child?.parentKey == "GH-4")
        #expect(child?.acceptanceCriteria == ["It works"])
        #expect(child?.blockedBy == ["API-9"])
        #expect(child?.description == "Part one.")
        #expect(child?.createdBy == .reconciler)
        #expect(await github.bodies("POST", "repos/o/r/issues/4/sub_issues") == [#"{"sub_issue_id":1005}"#])

        await github.setFailCreating(true)
        await #expect(throws: GitHubError.self) { try await tracker.createChildTicket(parent: "GH-4", spec: spec, by: .reconciler) }
    }

    @Test func problemsAreKeptForTheActivityLog() async {
        let tracker = GitHubIssuesTracker(repo: "o/r", transport: Failing())
        #expect(await tracker.tickets().isEmpty)
        #expect(await tracker.takeProblems() == ["Listing issues in o/r: nope"])
        #expect(await tracker.takeProblems().isEmpty)
    }

    @Test func findsTheRepoInGitHubRemotes() {
        #expect(GitHubIssuesTracker.repo(fromRemote: "git@github.com:Grepen74/agent-harness-os.git\n") == "Grepen74/agent-harness-os")
        #expect(GitHubIssuesTracker.repo(fromRemote: "https://github.com/o/r") == "o/r")
        #expect(GitHubIssuesTracker.repo(fromRemote: "https://gitlab.com/o/r.git") == nil)
    }

    @Test func aConfigChoosesTheTrackerOrSaysWhatsMissing() {
        let github = RepoConfig.Tracker(type: "github-issues")
        #expect(TrackerChoice.resolve(nil, remote: "git@github.com:o/r.git", hasGitHubCLI: true).0 == .local)
        let chosen = TrackerChoice.resolve(github, remote: "git@github.com:o/r.git", hasGitHubCLI: true)
        #expect(chosen.0 == .githubIssues(repo: "o/r"))
        #expect(chosen.1.map(\.severity) == [.info])
        #expect(TrackerChoice.resolve(.init(type: "github-issues", repo: "x/y"), remote: nil, hasGitHubCLI: true).0 == .githubIssues(repo: "x/y"))
        #expect(TrackerChoice.resolve(github, remote: "https://gitlab.com/o/r", hasGitHubCLI: true).1.map(\.severity) == [.blocker])
        #expect(TrackerChoice.resolve(github, remote: "git@github.com:o/r.git", hasGitHubCLI: false).1.map(\.severity) == [.blocker])
        #expect(TrackerChoice.resolve(.init(type: "jira"), remote: nil, hasGitHubCLI: true).1.map(\.severity) == [.blocker])
    }

    private struct Failing: GitHubTransport {
        func request(_ method: String, _ path: String, body: Data?) async throws -> Data { throw GitHubError(description: "nope") }
    }

    // MARK: A Projects board

    private func boardTracker(_ github: FakeGitHub, statusMap: [String: String]? = nil) -> GitHubIssuesTracker {
        GitHubIssuesTracker(repo: "o/r", transport: github,
                            project: .init(owner: "o", number: 1, statusMap: statusMap), listInterval: .zero)
    }

    @Test func withABoardTheStatusMovesTheCardAndWhatNeedsAttentionIsALabel() async {
        let github = FakeGitHub()
        await github.add(issue: 1, body: "x")
        let tracker = boardTracker(github)

        await tracker.setStatus(of: "GH-1", to: "In progress")
        #expect(await github.moves == ["#1 → In progress"])
        #expect(await github.paths("POST").filter { $0.hasSuffix("/labels") }.isEmpty)

        await tracker.setStatus(of: "GH-1", to: "Needs input")
        #expect(await github.moves == ["#1 → In progress"])
        #expect(await github.bodies("POST", "repos/o/r/issues/1/labels") == [#"{"labels":["agentos: Needs input"]}"#])

        await tracker.setStatus(of: "GH-1", to: "Done")
        #expect(await github.moves == ["#1 → In progress", "#1 → Done"])
        #expect(await github.paths("DELETE") == ["repos/o/r/issues/1/labels/agentos%3A%20Needs%20input"])
        #expect(await tracker.takeProblems().isEmpty)
    }

    @Test func aCardAlreadyInPlaceIsLeftAloneAndTheMapCanBeChanged() async {
        let github = FakeGitHub()
        await github.add(issue: 1, body: "x")
        await github.add(issue: 2, body: "y")
        await github.putOnBoard(1, at: "Ready")
        await github.putOnBoard(2, at: "Ready")
        let tracker = boardTracker(github, statusMap: ["Landing": "Done", "Ready": ""])

        await tracker.setStatus(of: "GH-1", to: "Landing")
        await tracker.setStatus(of: "GH-2", to: "Ready")
        #expect(await github.moves == ["#1 → Done"])
        #expect(await github.bodies("POST", "repos/o/r/issues/2/labels") == [#"{"labels":["agentos: Ready"]}"#])
    }

    @Test func anUnreadableBoardFallsBackToLabelsWithoutFloodingTheLog() async {
        let github = FakeGitHub()
        await github.add(issue: 1, body: "x")
        await github.setBoard(error: "Your token has not been granted the required scopes")
        let tracker = boardTracker(github)

        await tracker.setStatus(of: "GH-1", to: "In progress")
        await tracker.setStatus(of: "GH-1", to: "Done")
        #expect(await tracker.takeProblems().count == 1)
        #expect(await tracker.ticket("GH-1")?.status == "Done")
        #expect(await github.bodies("POST", "repos/o/r/issues/1/labels").count == 2)
    }

    @Test func theScanSaysWhetherTheBoardCanBeUsed() async {
        let github = FakeGitHub()
        let project = RepoConfig.Tracker.Project(owner: "o", number: 1)
        var findings = await GitHubProjectBoard.findings(config: project, repo: "o/r", transport: github, account: nil)
        #expect(findings.map(\.severity) == [.info])

        await github.setBoard(options: ["Todo", "In progress", "Done"])
        findings = await GitHubProjectBoard.findings(config: project, repo: "o/r", transport: github, account: nil)
        #expect(findings.map(\.severity) == [.info, .warning])
        #expect(findings.last?.detail.hasPrefix("Specifying → Backlog, Breaking down → Backlog, Ready → Ready, In review → In review, Landing → In review") == true)

        await github.setBoard(error: "The 'id' field requires one of the following scopes: ['read:project']")
        findings = await GitHubProjectBoard.findings(config: project, repo: "o/r", transport: github, account: "Grepen74")
        #expect(findings.map(\.severity) == [.warning])
        #expect(findings.first?.suggestion?.contains("gh auth refresh -s project --user Grepen74") == true)
    }
}
