import Foundation

public struct LabelMark: Codable, Sendable, Hashable {
    public let name: String
    /// Who set the label. The harness only obeys `harness:` labels set by humans.
    public let setBy: Participant
}

public struct Comment: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public let author: Participant
    public let text: String
    public var at = Date()
}

public struct Ticket: Codable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    public var title: String
    public var description: String
    public var acceptanceCriteria: [String]
    /// "Is blocked by" links to items in other systems, e.g. "BACKEND-42".
    public var blockedBy: [String]
    public var labels: [LabelMark] = []
    public var comments: [Comment] = []
    public var status = "To Do"
    public var parentKey: String?
    public let createdBy: Participant
}

/// A stand-in for Jira / GitHub Issues / Azure DevOps. Humans use it through the app.
/// It knows nothing about the harness: it just stores tickets.
public actor MockTracker {
    public nonisolated let fileURL: URL?
    public nonisolated let project: String
    private var store: [Ticket] = []
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(project: String = "APP", fileURL: URL?) {
        self.project = project
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? Hashing.decoder().decode([Ticket].self, from: data) {
            store = saved
        }
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
        if let fileURL {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Hashing.canonicalJSON(store).write(to: fileURL, options: .atomic)
        }
        for continuation in changeContinuations.values { continuation.yield() }
    }
}
