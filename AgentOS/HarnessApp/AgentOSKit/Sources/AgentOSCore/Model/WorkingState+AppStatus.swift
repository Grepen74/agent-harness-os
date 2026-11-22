import Foundation

extension WorkingState {
    /// Eligible requirements awaiting final verification, oldest pull request first, then creation order.
    public var verificationQueue: [NodeState] {
        roots.enumerated().filter {
            canQueueRequirement($0.element) && $0.element.activeRun == nil
                && (currentVerification(of: $0.element) == nil || $0.element.requirementVerificationRetryPending)
                && (!$0.element.requirementVerificationStarted || $0.element.requirementVerification != nil
                    || $0.element.requirementVerificationRetryPending)
        }.sorted {
            switch ($0.element.pullRequestNumber, $1.element.pullRequestNumber) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.offset < $1.offset
            }
        }.map(\.element)
    }

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
            let waiting = verificationQueue.filter { $0.pullRequestState == .open && $0.pullRequestNumber != nil }
            if let index = waiting.firstIndex(where: { $0.id == node.id }) {
                detail = "waiting for verification (\(Self.ordinal(index + 1)))"
            } else {
                detail = "waiting for verification"
            }
        }
        return "\(status) · #\(number) \(detail)"
    }

    private func canQueueRequirement(_ root: NodeState) -> Bool {
        guard (root.pullRequestNumber == nil || status(of: root) == "In review"),
              !root.ticketClosed, root.phase == .proven,
              !root.requirementMerged, root.pullRequestState != .closed, root.pullRequestState != .merged,
              root.pullRequestNumber == nil || root.publishedCommit != nil || root.requirementVerificationRetryPending,
              !lineage(of: root.id).contains(where: { !$0.flags.isEmpty || $0.overlapHold != nil }),
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
