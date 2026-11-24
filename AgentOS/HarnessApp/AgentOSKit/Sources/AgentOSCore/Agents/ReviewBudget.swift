import Foundation

/// Review rounds for the current work, shared by the controller and read-only presentations.
public enum ReviewBudget {
    /// Records must belong to one node and be in ledger order. Audit history is never discarded.
    public static func failures(in records: [RecordedEvent], stage: ReviewStage) -> [ReviewRecord] {
        let reset = records.lastIndex {
            switch $0.event.kind {
            case .attemptsReset, .replanned: return true
            case .phaseChanged(to: .specified), .flagCleared(.needsInput), .questionsAnswered:
                return $0.event.by.isHuman
            case .reviewRecorded(let review): return review.stage == stage && review.result.passed
            default: return false
            }
        }
        return records.dropFirst(reset.map { $0 + 1 } ?? 0).compactMap { record in
            guard case .reviewRecorded(let review) = record.event.kind,
                  review.stage == stage, !review.result.passed else { return nil }
            return review
        }
    }

    public static func isConverging(_ failures: [ReviewRecord]) -> Bool {
        guard failures.count >= 2 else { return false }
        let latest = failures[failures.count - 1].result.allFindings
        let before = failures[failures.count - 2].result.allFindings
        return (latest.count < before.count || !latest.isEmpty && latest.count == before.count) && latest.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("new:")
        }
    }

    public static func convergingRoundLimit(_ maxRounds: Int) -> Int { maxRounds * 2 }

    public static func allowance(for failures: [ReviewRecord], maxRounds: Int) -> Int {
        failures.count >= maxRounds && isConverging(failures) ? convergingRoundLimit(maxRounds) : maxRounds
    }
}
