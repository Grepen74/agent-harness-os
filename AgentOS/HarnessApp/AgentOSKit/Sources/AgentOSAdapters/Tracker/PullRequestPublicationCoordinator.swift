import AgentOSCore
import Foundation

/// Harness-owned publication. Only an explicit requirement ref can cross this boundary.
public actor PullRequestPublicationCoordinator: RequirementPublisher, RequirementPullRequestService {
    let ledger: Ledger
    private let tracker: any TrackerAdapter
    var repository: String
    let policy: EffectivePolicy
    let transport: any GitHubTransport
    private let git: @Sendable ([String]) async throws -> String
    private var reconciling = false
    var reconcilingVerificationStatuses = false
    var attemptedVerificationStatuses: Set<String> = []

    public init(ledger: Ledger, tracker: any TrackerAdapter, repository: String, policy: EffectivePolicy,
                transport: any GitHubTransport,
                git: @escaping @Sendable ([String]) async throws -> String) {
        self.ledger = ledger
        self.tracker = tracker
        self.repository = repository
        self.policy = policy
        self.transport = transport
        self.git = git
    }

    public func publish(requirement: NodeIdentity, branch: String, commit: String) async throws {
        let state = await ledger.workingState()
        guard let root = state.nodes[requirement.nodeID], root.identity == requirement else { return }
        try await reconcile([RequirementPublicationRequest(
            requirement: root.id, branch: branch, commit: commit,
            verification: root.requirementVerification.map { [$0] },
            proofs: state.subtree(of: root.id).flatMap(\.acceptanceCriterionProofs))])
    }

    public func reconcile(_ requests: [RequirementPublicationRequest]) async throws {
        guard policy.policy.pullRequests, !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        for request in requests {
            var state = await ledger.workingState()
            guard var root = state.nodes[request.requirement],
                  root.spec.parent == nil, !root.ticketClosed, !root.requirementMerged,
                  Self.safeBranch(request.branch, ticket: root.ticket),
                  !request.commit.isEmpty else { continue }
            guard root.pullRequestState != .closed || root.publicationRetryPending else { continue }
            if root.publicationFailure != nil, !root.publicationRetryPending {
                try await acceptRetry(for: root)
                state = await ledger.workingState()
                guard let updated = state.nodes[root.id] else { continue }
                root = updated
                guard root.publicationRetryPending else { continue }
            }
            guard root.catchUpConflict == nil,
                  !state.lineage(of: root.id).contains(where: { !$0.flags.isEmpty }) else { continue }
            let leaves = state.requirementLeaves(for: root.id)
            if root.pullRequestNumber == nil {
                guard !leaves.isEmpty, leaves.allSatisfy({ $0.phase == .proven }) else { continue }
                guard let verification = request.verification, !verification.isEmpty,
                      verification.allSatisfy({ $0.passed && $0.commit == request.commit }) else { continue }
            }
            guard root.publishedCommit != request.commit || root.publicationRetryPending else { continue }
            try await record(.requirementPublicationStarted, on: root.id)
            do {
                try await resolveRepository()
                let tip = try await git(["rev-parse", "--verify", "refs/heads/\(request.branch)"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard tip == request.commit else {
                    throw GitHubError(description: "Requirement branch moved from \(request.commit) to \(tip); verify its current tip before publishing.")
                }
                _ = try await push(branch: request.branch)
                try await record(.requirementPushed(branch: request.branch, commit: request.commit), on: root.id)
                try await postVerificationStatus(commit: request.commit, on: root.id)
                let title = "\(root.ticket): \(root.spec.title)"
                let body = PullRequestDescription.render(
                    request, root: root, state: state,
                    closesIssue: tracker.contextRepository == repository)
                let pr: PullRequest
                if let number = root.pullRequestNumber {
                    pr = try await update(number, title: title, body: body, allowReopen: root.publicationRetryPending)
                } else if let existing = try await findPullRequest(branch: request.branch) {
                    // Also recovers a successful create whose response was lost.
                    pr = try await update(existing.number, title: title, body: body, allowReopen: root.publicationRetryPending)
                } else {
                    pr = try await send("POST", collection, [
                        "head": request.branch, "base": "main", "title": title, "body": body,
                    ])
                }
                if root.pullRequestNumber == nil {
                    try await record(.requirementPullRequestOpened(number: pr.number, url: pr.html_url), on: root.id)
                } else if root.pullRequestState == .closed {
                    try await record(.requirementPullRequestReopened(number: pr.number, url: pr.html_url), on: root.id)
                }
                try await record(.requirementPublicationFinished(commit: request.commit), on: root.id)
                await tracker.comment(on: root.ticket,
                    "In review: published \(request.branch) at \(request.commit): \(pr.html_url). A person can review and merge the pull request.")
            } catch {
                let message = "Pull request publication failed: \(error). Fix the problem, then add harness:retry to push and open or update the same pull request. No automatic retry or agent rework will run."
                try await record(.requirementPublicationFailed(error: message), on: root.id)
                await tracker.comment(on: root.ticket, message)
            }
        }
    }

    private func acceptRetry(for root: NodeState) async throws {
        for signal in await tracker.pendingSignals() where signal.ticket == root.ticket && signal.command == .retry {
            guard signal.setBy.isHuman, policy.policy.allowedSignals.contains(.retry) else {
                let reason = "Only an allowed human harness:retry can retry publication."
                try await record(.signalRejected(ticket: root.ticket, command: .retry, reason: reason), on: root.id)
                await tracker.consume(signal, reply: reason)
                continue
            }
            try await ledger.append([
                LedgerEvent(node: root.id, by: signal.setBy, kind: .requirementPublicationRetryRequested),
                LedgerEvent(node: root.id, by: signal.setBy, kind: .signalAccepted(
                    ticket: root.ticket, command: .retry, reply: "Retrying publication; no agent rework.")),
            ])
            await tracker.consume(signal, reply: "harness:retry: pushing and opening or updating the same pull request again.")
        }
    }

    private static func safeBranch(_ branch: String, ticket: String) -> Bool {
        guard ticket.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil,
              ticket != "main", ticket != "leaf" else { return false }
        return branch == "agentos/\(ticket)"
    }

    private var collection: String { "repos/\(repository)/pulls" }

    func resolveRepository() async throws {
        guard repository.isEmpty else { return }
        let remote = try await git(["remote", "get-url", "--push", "origin"])
        guard let resolved = GitHubIssuesTracker.repo(fromRemote: remote) else {
            throw GitHubError(description: "origin must point to a GitHub repository before publishing pull requests.")
        }
        repository = resolved
    }

    public func pullRequest(number: Int) async throws -> RequirementPullRequest {
        try await resolveRepository()
        let data = try await transport.request("GET", "\(collection)/\(number)", body: nil)
        return try JSONDecoder().decode(PullRequest.self, from: data).snapshot
    }

    public func push(branch: String) async throws -> String {
        guard policy.policy.pullRequests, branch.hasPrefix("agentos/"),
              Self.safeBranch(branch, ticket: String(branch.dropFirst("agentos/".count))) else {
            throw GitHubError(description: "Only an enabled requirement branch may be pushed.")
        }
        let tip = try await git(["rev-parse", "--verify", "refs/heads/\(branch)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = "refs/heads/\(branch)"
        _ = try await git(["push", "--no-force", "--no-follow-tags", "--no-mirror",
                          "--recurse-submodules=no", "origin", "\(ref):\(ref)"])
        return tip
    }

    public func open(branch: String, title: String, body: String) async throws -> RequirementPullRequest {
        guard policy.policy.pullRequests, branch.hasPrefix("agentos/"),
              Self.safeBranch(branch, ticket: String(branch.dropFirst("agentos/".count))) else {
            throw GitHubError(description: "Only an enabled requirement branch may open a pull request.")
        }
        try await resolveRepository()
        if let existing = try await findPullRequest(branch: branch) {
            return try await update(existing.number, title: title, body: body, allowReopen: false).snapshot
        }
        return try await send("POST", collection, [
            "head": branch, "base": "main", "title": title, "body": body,
        ]).snapshot
    }

    public func reopen(number: Int) async throws -> RequirementPullRequest {
        guard policy.policy.pullRequests else {
            throw GitHubError(description: "Push / open pull requests is disabled.")
        }
        let existing = try await pullRequest(number: number)
        guard existing.state != .merged else {
            throw GitHubError(description: "Pull request \(existing.url) was merged; open a follow-up ticket instead.")
        }
        return try await send("PATCH", "\(collection)/\(number)", ["state": "open"]).snapshot
    }

    private struct PullRequest: Decodable {
        let number: Int
        let html_url: String
        let state: String
        let merged_at: String?

        var snapshot: RequirementPullRequest {
            RequirementPullRequest(number: number, url: html_url,
                state: merged_at != nil ? .merged : state == "closed" ? .closed : .open)
        }
    }

    private func findPullRequest(branch: String) async throws -> PullRequest? {
        var page = 1
        var matches: [PullRequest] = []
        repeat {
            var query = URLComponents()
            query.queryItems = [
                URLQueryItem(name: "state", value: "all"),
                URLQueryItem(name: "head", value: "\(repository.split(separator: "/").first ?? ""):\(branch)"),
                URLQueryItem(name: "base", value: "main"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: "\(page)"),
            ]
            let data = try await transport.request("GET", collection + (query.string ?? ""), body: nil)
            let prs = try JSONDecoder().decode([PullRequest].self, from: data)
            matches += prs
            if prs.count < 100 { break }
            page += 1
        } while true
        guard matches.count <= 1 else {
            throw GitHubError(description: "Multiple pull requests already exist for \(branch); a person must resolve the duplicates.")
        }
        return matches.first
    }

    private func update(_ number: Int, title: String, body: String, allowReopen: Bool) async throws -> PullRequest {
        let data = try await transport.request("GET", "\(collection)/\(number)", body: nil)
        let existing = try JSONDecoder().decode(PullRequest.self, from: data)
        guard existing.merged_at == nil else {
            throw GitHubError(description: "Pull request \(existing.html_url) was merged; open a follow-up ticket instead.")
        }
        guard existing.state != "closed" || allowReopen else {
            throw GitHubError(description: "Pull request \(existing.html_url) was closed without merging. Add harness:retry to reopen the same pull request.")
        }
        var fields = ["title": title, "body": body]
        if existing.state == "closed" { fields["state"] = "open" }
        return try await send("PATCH", "\(collection)/\(number)", fields)
    }

    private func send(_ method: String, _ path: String, _ fields: [String: String]) async throws -> PullRequest {
        let data = try await transport.request(method, path, body: JSONEncoder().encode(fields))
        return try JSONDecoder().decode(PullRequest.self, from: data)
    }

    func record(_ kind: EventKind, on node: NodeID) async throws {
        try await ledger.append([LedgerEvent(node: node, by: .adapter("Pull request publication"), kind: kind)])
    }
}
