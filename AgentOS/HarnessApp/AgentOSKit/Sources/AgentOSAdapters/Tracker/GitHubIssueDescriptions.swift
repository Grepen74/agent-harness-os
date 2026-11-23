import AgentOSCore
import Foundation

/// Keeps approval independent of live labels: consumed labels still accepted the body they covered.
actor GitHubIssueDescriptions {
    private struct EditorResponse: Decodable {
        struct Payload: Decodable {
            struct Repository: Decodable {
                let issue: Edit
            }
            let repository: Repository
        }
        let data: Payload
    }

    private struct Edit: Decodable {
        struct Editor: Decodable { let login: String }
        let body: String
        let editor: Editor?
        let lastEditedAt: Date?
    }

    private struct LabelEvent: Decodable {
        struct Actor: Decodable {
            let login: String
            let type: String?
        }
        struct Label: Decodable { let name: String }
        let event: String
        let actor: Actor?
        let label: Label?
        let createdAt: Date?
    }

    private let repo: String
    private let transport: any GitHubTransport
    private let permissions: GitHubCommentPermissions
    private var ledger: Ledger?
    private var observations: [String: TicketDescription] = [:]
    private var roundPermissions: [String: GitHubCommentPermissions.Decision] = [:]
    private var editCache: [Int: (revision: String, edit: Edit)] = [:]
    private var eventCache: [Int: (revision: String, events: [LabelEvent])] = [:]

    init(repo: String, transport: any GitHubTransport, permissions: GitHubCommentPermissions, ledger: Ledger?) {
        self.repo = repo
        self.transport = transport
        self.permissions = permissions
        self.ledger = ledger
    }

    func connectLedger(_ ledger: Ledger) async throws {
        if self.ledger === ledger { return }
        let stored = await ledger.workingState().ticketDescriptions
        for (ticket, description) in observations where stored[ticket] == nil {
            try await ledger.append([LedgerEvent(node: nil, by: .adapter("GitHub"),
                                                kind: .ticketDescriptionObserved(ticket: ticket, description: description))])
        }
        observations.merge(stored) { _, stored in stored }
        self.ledger = ledger
    }

    func beginRound() { roundPermissions.removeAll() }

    func body(number: Int, revision: String, current: String) async -> (body: String?, problems: [String]) {
        let key = "GH-\(number)"
        if let ledger {
            observations[key] = await ledger.workingState().ticketDescriptions[key]
        }
        let previous = observations[key]
        var problems: [String] = []
        var approval = previous?.acceptedAt
        do {
            let edit = try await readEdit(number, revision: revision)
            let events = try await labelEvents(number, revision: revision)
            for event in events where event.event == "labeled" && event.label?.name.hasPrefix("harness:") == true {
                guard let at = event.createdAt, at > (approval ?? .distantPast),
                      let actor = event.actor, actor.type != "Bot", !actor.login.hasSuffix("[bot]") else { continue }
                let decision = await permission(actor.login)
                if let problem = decision.problem { problems.append(problem) }
                if decision.allowed { approval = at }
            }
            if edit.editor == nil, let editedAt = edit.lastEditedAt,
               editedAt > (approval ?? .distantPast), approval != nil {
                throw GitHubError(description: "\(key): the description editor is unavailable. "
                    + "Keeping the accepted description until the editor can be checked.")
            }
            var heldEditor: String?
            if let editor = edit.editor, let editedAt = edit.lastEditedAt,
               editedAt > (approval ?? .distantPast) {
                let decision = await permission(editor.login)
                if let problem = decision.problem { problems.append(problem) }
                if decision.allowed {
                    approval = editedAt
                } else if let previous, previous.acceptedAt != nil {
                    // Unknown access never accepts an edit, and is retried at the next round.
                    if decision.problem == nil { heldEditor = editor.login }
                    else { heldEditor = previous.heldEditor }
                    let kept = TicketDescription(body: previous.body, acceptedAt: previous.acceptedAt,
                                                 heldEditor: heldEditor)
                    try await record(kept, for: key)
                    return (kept.body, problems)
                } else if approval != nil {
                    // A newly discovered old approval cannot approve a later outside edit.
                    throw GitHubError(description: "\(key): the description at approval is unavailable. "
                        + "A person with write access must edit the description or add harness:replan.")
                }
            }
            let accepted = TicketDescription(body: edit.body, acceptedAt: approval)
            try await record(accepted, for: key)
            return (accepted.body, problems)
        } catch {
            problems.append("Reading the accepted description of \(key): \(error)")
            if approval != nil, previous?.acceptedAt == nil { return (nil, problems) }
            return (previous?.body ?? current, problems)
        }
    }

    private func permission(_ login: String) async -> GitHubCommentPermissions.Decision {
        if let decision = roundPermissions[login], decision.problem != nil { return decision }
        let decision = await permissions.permission(for: login)
        roundPermissions[login] = decision
        return decision
    }

    private func record(_ description: TicketDescription, for ticket: String) async throws {
        guard observations[ticket] != description else { return }
        if let ledger {
            try await ledger.append([LedgerEvent(node: nil, by: .adapter("GitHub"),
                                                kind: .ticketDescriptionObserved(ticket: ticket, description: description))])
        }
        observations[ticket] = description
    }

    private func readEdit(_ number: Int, revision: String) async throws -> Edit {
        if let cached = editCache[number], cached.revision == revision { return cached.edit }
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw GitHubError(description: "Expected a repository in owner/name form.") }
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            issue(number: $number) { body lastEditedAt editor { login } }
          }
        }
        """
        let body = try JSONSerialization.data(withJSONObject: [
            "query": query, "variables": ["owner": parts[0], "name": parts[1], "number": number]
        ])
        let data = try await transport.request("POST", "graphql", body: body)
        let edit = try Self.decoder().decode(EditorResponse.self, from: data).data.repository.issue
        editCache[number] = (revision, edit)
        return edit
    }

    private func labelEvents(_ number: Int, revision: String) async throws -> [LabelEvent] {
        if let cached = eventCache[number], cached.revision == revision { return cached.events }
        var events: [LabelEvent] = []
        for page in 1...20 {
            let data = try await transport.request(
                "GET", "repos/\(repo)/issues/\(number)/events?per_page=100&page=\(page)", body: nil)
            let items = try Self.decoder().decode([LabelEvent].self, from: data)
            events += items
            if items.count < 100 { break }
        }
        eventCache[number] = (revision, events)
        return events
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
