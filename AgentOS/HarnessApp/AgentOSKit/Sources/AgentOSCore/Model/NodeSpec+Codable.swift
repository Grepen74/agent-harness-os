import Foundation

extension NodeSpec {
    private enum CodingKeys: String, CodingKey {
        case id, parent, kind, title, intent, acceptanceCriteria, touches, predictedPaths, dependsOn, after, profile
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(NodeID.self, forKey: .id)
        parent = try container.decodeIfPresent(NodeID.self, forKey: .parent)
        kind = try container.decode(NodeKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        intent = try container.decode(String.self, forKey: .intent)
        acceptanceCriteria = try container.decode([String].self, forKey: .acceptanceCriteria)
        touches = try container.decode([String].self, forKey: .touches)
        predictedPaths = try container.decodeIfPresent([String].self, forKey: .predictedPaths) ?? []
        dependsOn = try container.decode([String].self, forKey: .dependsOn)
        after = try container.decodeIfPresent([String].self, forKey: .after)
        profile = try container.decode(String.self, forKey: .profile)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(parent, forKey: .parent)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(intent, forKey: .intent)
        try container.encode(acceptanceCriteria, forKey: .acceptanceCriteria)
        try container.encode(touches, forKey: .touches)
        // Omitting empty predictions preserves the canonical bytes of older ledger records.
        if !predictedPaths.isEmpty { try container.encode(predictedPaths, forKey: .predictedPaths) }
        try container.encode(dependsOn, forKey: .dependsOn)
        try container.encodeIfPresent(after, forKey: .after)
        try container.encode(profile, forKey: .profile)
    }
}
