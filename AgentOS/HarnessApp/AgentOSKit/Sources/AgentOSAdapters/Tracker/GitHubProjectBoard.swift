import AgentOSCore
import Foundation

/// The status field of a GitHub Projects board, kept in step with the harness's status of each issue. Named in
/// the repo config (`tracker.project`); one way only: moving a card never asks the harness for anything, that
/// stays with `harness:` labels. Projects are only reachable through GraphQL, and need the `project` scope.
actor GitHubProjectBoard {
    struct Resolved: Sendable {
        let projectID: String
        let title: String
        let fieldID: String
        /// Lowercased option name → option id.
        let options: [String: String]
    }

    private struct Item {
        let id: String
        var option: String?
    }

    nonisolated let config: RepoConfig.Tracker.Project
    nonisolated let repo: String
    private let transport: any GitHubTransport
    private var resolved: Resolved?
    private var failedAt: ContinuousClock.Instant?
    /// The issue's card on the board and its option, by issue number.
    private var items: [Int: Item] = [:]

    /// Harness statuses (`Policy.trackerStatus`) → options of GitHub's default board. The ones needing attention
    /// (Needs input, Needs human, Blocked) have none: they stay labels, and the card stays where it was.
    static let defaultMap = ["Specifying": "Backlog", "Breaking down": "Backlog", "Ready": "Ready", "In progress": "In progress",
                             "In review": "In review", "Landing": "In review", "Done": "Done"]
    static let harnessStatuses = ["Specifying", "Breaking down", "Ready", "In progress", "In review", "Landing", "Done",
                                  "Needs input", "Needs human", "Blocked"]
    /// After a failed read, the board is left alone this long (labels meanwhile), so the log isn't flooded.
    static let retryAfter: Duration = .seconds(300)

    init(config: RepoConfig.Tracker.Project, repo: String, transport: any GitHubTransport) {
        self.config = config
        self.repo = repo
        self.transport = transport
    }

    nonisolated var name: String { "\(config.owner)#\(config.number)" }
    nonisolated var fieldName: String { config.statusField ?? "Status" }

    nonisolated func optionName(for status: String) -> String? {
        let name = config.statusMap?[status] ?? Self.defaultMap[status]
        return name?.isEmpty == false ? name : nil
    }

    /// Whether the board shows this status: it's mapped and the option exists. Nil while the board can't be read.
    func shows(_ status: String) async throws -> Bool? {
        guard let name = optionName(for: status) else { return false }
        guard let resolved = try await resolve() else { return nil }
        return resolved.options[name.lowercased()] != nil
    }

    /// Moves the issue's card (adding the issue to the board if needed). Nothing is written when it's already there.
    func set(issue number: Int, to status: String) async throws {
        guard let name = optionName(for: status), let resolved = try await resolve(),
              let option = resolved.options[name.lowercased()] else { return }
        let item = try await item(for: number, in: resolved)
        guard item.option?.lowercased() != name.lowercased() else { return }
        _ = try await graphql("""
            mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
              updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field,
                                                    value: {singleSelectOptionId: $option}}) { projectV2Item { id } }
            }
            """, ["project": resolved.projectID, "item": item.id, "field": resolved.fieldID, "option": option])
        items[number] = Item(id: item.id, option: name)
    }

    /// The board, its field and options. Nil while waiting to try again after a failure.
    func resolve() async throws -> Resolved? {
        if let resolved { return resolved }
        if let failedAt, ContinuousClock.now - failedAt < Self.retryAfter { return nil }
        do {
            let found = try await read()
            resolved = found
            return found
        } catch {
            failedAt = .now
            throw error
        }
    }

    /// For the readiness scan: whether the board can be used, and which statuses it can't show.
    static func findings(config: RepoConfig.Tracker.Project, repo: String, transport: any GitHubTransport,
                         account: String?) async -> [Finding] {
        let board = GitHubProjectBoard(config: config, repo: repo, transport: transport)
        let resolved: Resolved
        do {
            resolved = try await board.read()
        } catch {
            let text = "\(error)"
            let scope = text.contains("scope")
            return [Finding(
                check: "tracker.project", severity: .warning, title: "Can't use the board \(board.name)",
                detail: "Issues still work; the status shows as an agentos: label instead. \(text)",
                suggestion: scope ? "`gh auth refresh -s project\(account.map { " --user \($0)" } ?? "")`, then rescan."
                    : "Check `tracker.project` in .agentos/config.json.")]
        }
        var findings = [Finding(
            check: "tracker.project", severity: .info, title: "Status shows on the board \"\(resolved.title)\"",
            detail: "Its \(board.fieldName) field follows the harness, one way: moving a card doesn't ask the harness for anything.")]
        let missing = harnessStatuses.compactMap { status in
            board.optionName(for: status).flatMap { resolved.options[$0.lowercased()] == nil ? "\(status) → \($0)" : nil }
        }
        if !missing.isEmpty {
            findings.append(Finding(
                check: "tracker.project", severity: .warning, title: "The board has no option for some statuses",
                detail: "\(missing.joined(separator: ", ")). These show as agentos: labels.",
                suggestion: "Add the options to the board's \(board.fieldName) field, or map them in `tracker.project.statusMap`."))
        }
        return findings
    }

    // MARK: GraphQL

    private func read() async throws -> Resolved {
        let projectFields = """
            projectV2(number: $number) {
              id title
              field(name: $field) { ... on ProjectV2SingleSelectField { id options { id name } } }
            }
            """
        let data = try await graphql("""
            query($owner: String!, $number: Int!, $field: String!) {
              repositoryOwner(login: $owner) {
                ... on User { \(projectFields) }
                ... on Organization { \(projectFields) }
              }
            }
            """, ["owner": config.owner, "number": config.number, "field": fieldName])
        guard let project = Self.dig(data, "repositoryOwner", "projectV2") as? [String: Any],
              let projectID = project["id"] as? String else {
            throw GitHubError(description: "No board \(name) found.")
        }
        guard let field = project["field"] as? [String: Any], let fieldID = field["id"] as? String,
              let options = field["options"] as? [[String: Any]] else {
            throw GitHubError(description: "The board has no single-select field \"\(fieldName)\".")
        }
        var byName: [String: String] = [:]
        for option in options {
            if let name = option["name"] as? String, let id = option["id"] as? String { byName[name.lowercased()] = id }
        }
        return Resolved(projectID: projectID, title: project["title"] as? String ?? name, fieldID: fieldID, options: byName)
    }

    private func item(for number: Int, in resolved: Resolved) async throws -> Item {
        if let known = items[number] { return known }
        let parts = repo.split(separator: "/").map(String.init)
        let data = try await graphql("""
            query($owner: String!, $name: String!, $number: Int!, $field: String!) {
              repository(owner: $owner, name: $name) {
                issue(number: $number) {
                  id
                  projectItems(first: 50) {
                    nodes { id project { id } fieldValueByName(name: $field) { ... on ProjectV2ItemFieldSingleSelectValue { name } } }
                  }
                }
              }
            }
            """, ["owner": parts.first ?? "", "name": parts.last ?? "", "number": number, "field": fieldName])
        guard let issue = Self.dig(data, "repository", "issue") as? [String: Any], let issueID = issue["id"] as? String else {
            throw GitHubError(description: "Issue #\(number) not found.")
        }
        let cards = Self.dig(issue, "projectItems", "nodes") as? [[String: Any]] ?? []
        if let card = cards.first(where: { Self.dig($0, "project", "id") as? String == resolved.projectID }),
           let id = card["id"] as? String {
            let item = Item(id: id, option: Self.dig(card, "fieldValueByName", "name") as? String)
            items[number] = item
            return item
        }
        let added = try await graphql("""
            mutation($project: ID!, $content: ID!) {
              addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } }
            }
            """, ["project": resolved.projectID, "content": issueID])
        guard let id = Self.dig(added, "addProjectV2ItemById", "item", "id") as? String else {
            throw GitHubError(description: "Couldn't add #\(number) to the board.")
        }
        let item = Item(id: id, option: nil)
        items[number] = item
        return item
    }

    /// The response's `data`; GraphQL reports errors in the body, so they're thrown here.
    private func graphql(_ query: String, _ variables: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let response = try await transport.request("POST", "graphql", body: body)
        let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] ?? [:]
        if let errors = object["errors"] as? [[String: Any]], !errors.isEmpty {
            throw GitHubError(description: errors.compactMap { $0["message"] as? String }.joined(separator: " "))
        }
        return object["data"] as? [String: Any] ?? [:]
    }

    private static func dig(_ object: Any?, _ path: String...) -> Any? {
        path.reduce(object) { ($0 as? [String: Any])?[$1] }
    }
}
