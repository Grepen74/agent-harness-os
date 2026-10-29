import Foundation

/// A label on a ticket, with who set it. The harness only obeys `harness:` labels set by humans.
public struct LabelMark: Codable, Sendable, Hashable {
    public let name: String
    public let setBy: Participant

    public init(name: String, setBy: Participant) {
        self.name = name
        self.setBy = setBy
    }
}

public struct Comment: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public let author: Participant
    public let text: String
    public var at = Date()

    public init(author: Participant, text: String) {
        self.author = author
        self.text = text
    }
}

/// A ticket as the harness sees it, whatever tracker it came from (doc 03).
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

    public init(key: String, title: String, description: String, acceptanceCriteria: [String],
                blockedBy: [String] = [], parentKey: String? = nil, createdBy: Participant) {
        self.key = key
        self.title = title
        self.description = description
        self.acceptanceCriteria = acceptanceCriteria
        self.blockedBy = blockedBy
        self.parentKey = parentKey
        self.createdBy = createdBy
    }
}
