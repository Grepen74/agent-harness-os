import Foundation

extension WorkingState {
    /// The ticket status with app-only verification detail for an open requirement pull request.
    public func appStatus(of node: NodeState) -> String {
        let status = status(of: node)
        guard status == "In review", node.spec.parent == nil, node.pullRequestState == .open,
              let number = node.pullRequestNumber else { return status }
        let detail: String
        if node.activeRun?.role == .verifier {
            detail = "verifying"
        } else if let result = currentVerification(of: node), !node.requirementVerificationRetryPending {
            detail = result.passed ? "verified" : "verification failed"
        } else {
            let waiting = roots.filter {
                canQueueRequirement($0) && $0.pullRequestState == .open && $0.pullRequestNumber != nil
                    && $0.activeRun?.role != .verifier
                    && (currentVerification(of: $0) == nil || $0.requirementVerificationRetryPending)
            }.sorted { $0.pullRequestNumber! < $1.pullRequestNumber! }
            if let index = waiting.firstIndex(where: { $0.id == node.id }) {
                detail = "waiting for verification (\(Self.ordinal(index + 1)))"
            } else {
                detail = "waiting for verification"
            }
        }
        return "\(status) · #\(number) \(detail)"
    }

    private func canQueueRequirement(_ root: NodeState) -> Bool {
        guard status(of: root) == "In review", !root.ticketClosed, root.phase == .proven,
              !root.requirementMerged,
              root.publishedCommit != nil || root.requirementVerificationRetryPending,
              !lineage(of: root.id).contains(where: { $0.catchUpConflict != nil }) else { return false }
        let leaves = requirementLeaves(for: root.id)
        return !leaves.isEmpty && leaves.allSatisfy { $0.phase == .proven }
    }

    private func currentVerification(of node: NodeState) -> Evidence? {
        guard let result = node.requirementVerification,
              let tip = node.requirementBranchObservation?.tip ?? node.publishedCommit,
              result.commit == tip else { return nil }
        return result
    }

    private static func ordinal(_ place: Int) -> String {
        let suffix: String
        switch place % 100 {
        case 11...13: suffix = "th"
        default:
            switch place % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(place)\(suffix)"
    }
}
