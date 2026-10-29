import AgentOSCore
import Foundation

/// A small tracker inside the app, for repos without a tracker adapter, and the simulator's stand-in
/// for Jira / GitHub Issues / Azure DevOps. Humans use it through the app.
/// It knows nothing about the harness: it just stores tickets (in a `TicketStore`).
public actor LocalTracker {
    public nonisolated let project: String
    private let persistence: (any TicketStore)?
    private var store: [Ticket] = []
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Pass nil to keep tickets in memory only.
    public init(project: String = "APP", store persistence: (any TicketStore)?) {
        self.project = project
        self.persistence = persistence
        store = (try? persistence?.load()) ?? []
    }

    public func tickets() -> [Ticket] { store }

    public func ticket(_ key: String) -> Ticket? { store.first { $0.key == key } }

    /// Fires whenever any ticket changes (for live views).
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        changeContinuations[id] = continuation
        return stream
    }

    @discardableResult
    public func createTicket(
        title: String, description: String, acceptanceCriteria: [String],
        blockedBy: [String] = [], parentKey: String? = nil, by author: Participant
    ) -> Ticket {
        let ticket = Ticket(
            key: "\(project)-\(store.count + 1)", title: title, description: description,
            acceptanceCriteria: acceptanceCriteria, blockedBy: blockedBy, parentKey: parentKey, createdBy: author)
        store.append(ticket)
        save()
        return ticket
    }

    public func addLabel(_ name: String, to key: String, by who: Participant) {
        mutate(key) { ticket in
            guard !ticket.labels.contains(where: { $0.name == name }) else { return }
            ticket.labels.append(LabelMark(name: name, setBy: who))
        }
    }

    public func removeLabel(_ name: String, from key: String) {
        mutate(key) { $0.labels.removeAll { $0.name == name } }
    }

    public func addComment(_ text: String, to key: String, by who: Participant) {
        mutate(key) { $0.comments.append(Comment(author: who, text: text)) }
    }

    public func setStatus(_ status: String, of key: String) {
        guard ticket(key)?.status != status else { return }
        mutate(key) { $0.status = status }
    }

    public func edit(_ key: String, title: String, description: String, acceptanceCriteria: [String], blockedBy: [String]) {
        mutate(key) {
            $0.title = title
            $0.description = description
            $0.acceptanceCriteria = acceptanceCriteria
            $0.blockedBy = blockedBy
        }
    }

    private func mutate(_ key: String, _ change: (inout Ticket) -> Void) {
        guard let index = store.firstIndex(where: { $0.key == key }) else { return }
        change(&store[index])
        save()
    }

    private func save() {
        try? persistence?.save(store)
        for continuation in changeContinuations.values { continuation.yield() }
    }
}
