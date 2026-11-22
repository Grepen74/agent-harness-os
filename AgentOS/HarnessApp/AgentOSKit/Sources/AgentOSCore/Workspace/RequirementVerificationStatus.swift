/// The GitHub commit status for final verification of a pushed requirement commit.
public enum RequirementVerificationStatus: String, Codable, Hashable, Sendable {
    case pending, success, failure
}
