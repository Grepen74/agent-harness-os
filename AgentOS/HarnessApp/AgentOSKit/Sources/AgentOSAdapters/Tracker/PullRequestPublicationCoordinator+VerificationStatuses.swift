import AgentOSCore
import Foundation

extension PullRequestPublicationCoordinator {
    public func verificationStarted(requirement: NodeIdentity, commit: String) async throws {
        try await postVerificationStatus(commit: commit, on: requirement.nodeID, running: true)
    }

    public func verificationFinished(requirement: NodeIdentity, commit: String) async throws {
        try await postVerificationStatus(commit: commit, on: requirement.nodeID)
    }

    /// Replays every pushed commit, including results that completed after the branch moved.
    public func reconcileVerificationStatuses() async throws {
        guard policy.policy.pullRequests, !reconcilingVerificationStatuses else { return }
        reconcilingVerificationStatuses = true
        defer {
            reconcilingVerificationStatuses = false
            attemptedVerificationStatuses.removeAll()
        }
        let records = await ledger.allRecords()
        for record in records {
            guard let node = record.event.node,
                  case .requirementPushed(_, let commit) = record.event.kind else { continue }
            try await postVerificationStatus(commit: commit, on: node)
        }
    }

    func postVerificationStatus(commit: String, on node: NodeID, running: Bool = false) async throws {
        guard policy.policy.pullRequests else { return }
        let records = await ledger.records(for: node)
        guard records.contains(where: {
            if case .requirementPushed(_, let pushed) = $0.event.kind { return pushed == commit }
            return false
        }) else { return }
        let result = records.reversed().compactMap { record -> Evidence? in
            guard case .requirementVerificationFinished(let evidence) = record.event.kind,
                  evidence.commit == commit else { return nil }
            return evidence
        }.first
        let status: RequirementVerificationStatus = running ? .pending :
            result.map { $0.passed ? .success : .failure } ?? .pending
        let allRecords = await ledger.allRecords()
        let lastPosted = allRecords.last(where: {
            if case .requirementVerificationStatusPosted(let postedCommit, let postedState) = $0.event.kind {
                return postedCommit == commit && postedState == status
            }
            return false
        })
        let lastTransition = allRecords.last(where: {
            if case .requirementVerificationStatusPosted(let postedCommit, _) = $0.event.kind {
                return postedCommit == commit
            }
            return false
        })
        let started = records.last {
            if case .requirementVerificationStarted = $0.event.kind { return true }
            return false
        }
        let alreadyPosted = lastPosted != nil && lastPosted?.position == lastTransition?.position &&
            (!running || (lastPosted?.position ?? 0) > (started?.position ?? 0))
        guard !alreadyPosted, attemptedVerificationStatuses.insert(commit).inserted else { return }
        let description: String
        switch status {
        case .pending:
            description = running ? "Final verification running" : "Waiting for final verification"
        case .success:
            description = "Final verification passed"
        case .failure:
            let summary = result?.summary ?? ""
            description = summary.count > 140 ? String(summary.prefix(139)) + "…" : summary
        }
        do {
            try await resolveRepository()
            let body = try JSONEncoder().encode([
                "context": "agentos/verified", "state": status.rawValue, "description": description,
            ])
            _ = try await transport.request("POST", "repos/\(repository)/statuses/\(commit)", body: body)
        } catch {
            let message = "agentos/verified status post failed at \(commit): \(error). " +
                "Check GitHub access; the harness will retry automatically next round. No agent rework will run."
            try await record(.requirementVerificationStatusPostFailed(commit: commit, error: message), on: node)
            return
        }
        try await record(.requirementVerificationStatusPosted(commit: commit, state: status), on: node)
        attemptedVerificationStatuses.remove(commit)
    }
}
