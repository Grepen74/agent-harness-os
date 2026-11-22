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

public enum CommentWriteAccess: String, Codable, Sendable, Hashable {
    case allowed, denied, unknown
}

public struct Comment: Codable, Sendable, Hashable, Identifiable {
    public var id = UUID()
    public let author: Participant
    public let text: String
    public var at = Date()
    private var permission: CommentWriteAccess?

    /// Legacy bridge: nil means no permission decision, never a confirmed denial.
    public var authorCanProvideInput: Bool? {
        get {
            switch permission {
            case .allowed: true
            case .denied: false
            case .unknown, nil: nil
            }
        }
        set { permission = newValue.map { $0 ? .allowed : .denied } ?? .unknown }
    }

    /// Unreadable permissions are untrusted, but are not confirmed denials.
    public var writeAccess: CommentWriteAccess {
        get { permission ?? .allowed }
        set { permission = newValue }
    }

    public init(author: Participant, text: String) {
        self.author = author
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case id, author, text, at, authorCanProvideInput, writeAccess
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        author = try values.decode(Participant.self, forKey: .author)
        text = try values.decode(String.self, forKey: .text)
        at = try values.decode(Date.self, forKey: .at)
        if let access = try values.decodeIfPresent(CommentWriteAccess.self, forKey: .writeAccess) {
            permission = access
        } else {
            permission = try values.decodeIfPresent(Bool.self, forKey: .authorCanProvideInput)
                .map { $0 ? .allowed : .denied }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(author, forKey: .author)
        try values.encode(text, forKey: .text)
        try values.encode(at, forKey: .at)
        try values.encodeIfPresent(authorCanProvideInput, forKey: .authorCanProvideInput)
        try values.encodeIfPresent(permission, forKey: .writeAccess)
    }

    /// A person's note for other people (a diagnosis, a status update): never an answer, a correction or agent context.
    public static let agentIgnoreMarker = "<!-- agentos:ignore -->"

    /// A person's comment that agents and the harness may act on.
    public var isHumanInput: Bool {
        author.isHuman && writeAccess == .allowed && !text.contains(Self.agentIgnoreMarker)
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
