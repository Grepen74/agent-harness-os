import Foundation

extension Reconciler {
    func costComment(for parent: NodeState, in state: WorkingState) -> String {
        let breakdown = state.subtree(of: parent.id)
        let leaves = breakdown.filter { $0.spec.kind == .leaf }
        let composites = breakdown.filter { $0.spec.kind == .composite }
        let compositeCredits = composites.reduce(0) { $0 + $1.recordedAICredits }
        let compositeMissingCosts = composites.reduce(0) { $0 + $1.runsWithoutRecordedCost }
        let total = leaves.reduce(compositeCredits) { $0 + $1.recordedAICredits }
        let lowerBound = breakdown.contains { $0.runsWithoutRecordedCost > 0 } ? "at least " : ""
        let rows = leaves.map {
            "\(workLink($0)): \(creditAmount($0.recordedAICredits, missingRuns: $0.runsWithoutRecordedCost))"
        }
        return (rows + [
            "**Breakdown:** \(creditAmount(compositeCredits, missingRuns: compositeMissingCosts))",
            "**Total:** \(lowerBound)\(creditAmount(total))",
        ]).joined(separator: "\n")
    }

    private func creditAmount(_ amount: Double, missingRuns: Int = 0) -> String {
        let formatted = amount.formatted(
            .number.locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never).precision(.fractionLength(0...2))
        )
        let marker = missingRuns > 0
            ? " (\(missingRuns) \(missingRuns == 1 ? "run" : "runs") without a reported cost)" : ""
        return "\(formatted) AI credits\(marker)"
    }
}
