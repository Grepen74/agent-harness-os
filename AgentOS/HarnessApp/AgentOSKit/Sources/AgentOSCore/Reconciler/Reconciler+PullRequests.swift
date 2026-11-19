extension Reconciler {
    func observeRequirementPullRequests(_ report: inout RoundReport) async throws {
        guard let pullRequests else { return }
        isObservingPullRequests = true
        defer { isObservingPullRequests = false }
        for root in await ledger.workingState().roots {
            guard let number = root.pullRequestNumber, root.pullRequestState != .merged else { continue }
            let pr = try await pullRequests.pullRequest(number: number)
            guard pr.number == number else {
                throw AgentFailure("Expected pull request #\(number), received #\(pr.number).")
            }
            guard pr.state != root.pullRequestState else { continue }
            let event: EventKind
            let message: String
            switch pr.state {
            case .open:
                event = .requirementPullRequestReopened(number: pr.number, url: pr.url)
                message = "In review: pull request \(pr.url) is open for a person to review and merge."
            case .merged:
                event = .requirementPullRequestMerged(number: pr.number, url: pr.url)
                message = "Done: pull request \(pr.url) was merged. Open a follow-up ticket for further work."
            case .closed:
                event = .requirementPullRequestClosed(number: pr.number, url: pr.url)
                message = "Needs input: pull request \(pr.url) was closed without merging. Add harness:retry to push the branch again and reopen the same pull request."
            }
            try await write(root.id, by: .adapter("Pull requests"), [event])
            await tracker.comment(on: root.ticket, message)
            report.actions.append("\(root.displayName): \(message)")
        }
    }
}
