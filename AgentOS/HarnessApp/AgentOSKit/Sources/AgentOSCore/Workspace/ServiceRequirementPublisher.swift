/// Publishes through the injected capability, preserving the ledger's single PR identity.
struct ServiceRequirementPublisher: RequirementPublisher {
    let ledger: Ledger
    let tracker: any TrackerAdapter
    let service: any RequirementPullRequestService

    func publish(requirement: NodeIdentity, branch: String, commit: String) async throws {
        let state = await ledger.workingState()
        guard let root = state.nodes[requirement.nodeID], root.identity == requirement,
              !root.requirementMerged else { return }
        try await record(.requirementPublicationStarted, on: root.id)
        do {
            let pushed = try await service.push(branch: branch)
            guard pushed == commit else {
                throw AgentFailure("Requirement branch moved from \(commit) to \(pushed); verify its current tip before publishing.")
            }
            try await record(.requirementPushed(branch: branch, commit: pushed), on: root.id)
            if let number = root.pullRequestNumber {
                if root.pullRequestState == .closed {
                    let pr = try await service.reopen(number: number)
                    guard pr.number == number, pr.state == .open else {
                        throw AgentFailure("Could not reopen the original pull request #\(number).")
                    }
                    try await record(.requirementPullRequestReopened(number: pr.number, url: pr.url), on: root.id)
                }
            } else {
                let request = RequirementPublicationRequest(
                    requirement: root.id, branch: branch, commit: commit,
                    verification: root.requirementVerification.map { [$0] },
                    proofs: state.subtree(of: root.id).flatMap(\.acceptanceCriterionProofs))
                let body = PullRequestDescription.render(
                    request, root: root, state: state, closesIssue: !tracker.contextRepository.isEmpty)
                let pr = try await service.open(branch: branch, title: "\(root.ticket): \(root.spec.title)", body: body)
                try await record(.requirementPullRequestOpened(number: pr.number, url: pr.url), on: root.id)
            }
            try await record(.requirementPublicationFinished(commit: pushed), on: root.id)
            let current = await ledger.workingState().nodes[root.id]
            await tracker.comment(on: root.ticket,
                "In review: \(current?.pullRequestURL ?? branch). A person can review and merge the pull request.")
        } catch {
            let message = "Pull request publication failed: \(error). Fix the problem, then add harness:retry to push and open or update the same pull request. No automatic retry or agent rework will run."
            try await record(.requirementPublicationFailed(error: message), on: root.id)
            await tracker.comment(on: root.ticket, message)
        }
    }

    private func record(_ kind: EventKind, on node: NodeID) async throws {
        try await ledger.append([LedgerEvent(node: node, by: .adapter("Pull request publication"), kind: kind)])
    }
}
