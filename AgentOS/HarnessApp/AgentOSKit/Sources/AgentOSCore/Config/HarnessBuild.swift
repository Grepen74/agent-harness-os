/// The source revision used to build the harness, when known.
public struct HarnessBuild: Codable, Sendable, Equatable {
    public let commit: String?
    public let modified: Bool

    public init(commit: String?, modified: Bool) {
        self.commit = commit
        self.modified = modified
    }

    public var summary: String {
        guard let commit else { return "unknown" }
        return String(commit.prefix(7)) + (modified ? " (modified)" : "")
    }

    init(legacyValue: String) {
        let modified = legacyValue.hasSuffix("-modified")
        self.init(
            commit: legacyValue == "unknown" ? nil
                : modified ? String(legacyValue.dropLast("-modified".count)) : legacyValue,
            modified: modified
        )
    }
}
