/// The remote lifecycle of a requirement's single pull request.
public struct RequirementPullRequest: Sendable {
    public enum State: Sendable {
        case open, merged, closed
    }

    public let number: Int
    public let url: String
    public let state: State

    public init(number: Int, url: String, state: State) {
        self.number = number
        self.url = url
        self.state = state
    }
}

/// Harness-owned capabilities; never passed to agents.
public protocol RequirementPullRequestService: Sendable {
    func pullRequest(number: Int) async throws -> RequirementPullRequest
    func push(branch: String) async throws -> String
    func open(branch: String, title: String, body: String) async throws -> RequirementPullRequest
    func reopen(number: Int) async throws -> RequirementPullRequest
}
