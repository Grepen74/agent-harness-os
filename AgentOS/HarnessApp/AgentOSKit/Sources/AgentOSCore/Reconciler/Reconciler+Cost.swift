import Foundation

extension Reconciler {
    func costComment(for parent: NodeState, in state: WorkingState) -> String {
        let breakdown = state.subtree(of: parent.id)
        let leaves = breakdown.filter { $0.spec.kind == .leaf }
        let compositeCredits = breakdown.filter { $0.spec.kind == .composite }
            .reduce(0) { $0 + $1.recordedAICredits }
        let total = leaves.reduce(compositeCredits) { $0 + $1.recordedAICredits }
        let rows = leaves.map { "\(workLink($0)): \(creditAmount($0.recordedAICredits))" }
        return (rows + [
            "**Breakdown:** \(creditAmount(compositeCredits))",
            "**Total:** \(creditAmount(total))",
        ]).joined(separator: "\n")
    }

    private func creditAmount(_ amount: Double) -> String {
        let formatted = amount.formatted(
            .number.locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never).precision(.fractionLength(0...2))
        )
        return "\(formatted) AI credits"
    }
}
