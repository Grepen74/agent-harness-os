/// Advisory problems in a proposed breakdown, with 1-based proposal and criterion positions.
public enum BreakdownFinding: Equatable, Sendable {
    case vagueReference(childPosition: Int, childTitle: String,
                        criterionPosition: Int, criterionText: String)
    case scopeCriterion(childPosition: Int, childTitle: String,
                        criterionPosition: Int, criterionText: String)
    case unorderedOverlap(firstChildPosition: Int, firstChildTitle: String,
                          secondChildPosition: Int, secondChildTitle: String,
                          sharedComponents: [String])

    public var severity: Finding.Severity { .warning }
}

/// Checks proposal values without changing them or consulting external state.
public enum BreakdownChecker {
    private static let vaguePhrases = [
        "existing rule", "as agreed", "same as", "as before", "the agreed", "see child"
    ]
    private static let scopePhrases = ["doesn't change", "does not change", "unchanged"]

    public static func check(_ children: [ChildProposal]) -> [BreakdownFinding] {
        var findings: [BreakdownFinding] = []
        var ancestors: [Set<Int>] = []
        let components = children.map { child in
            Set((child.touches ?? []).map { ComponentName.from($0) })
        }

        for (childIndex, child) in children.enumerated() {
            for (criterionIndex, criterion) in child.acceptanceCriteria.enumerated() {
                let text = criterion.lowercased()
                if vaguePhrases.contains(where: { text.contains($0) }) {
                    findings.append(.vagueReference(
                        childPosition: childIndex + 1, childTitle: child.title,
                        criterionPosition: criterionIndex + 1, criterionText: criterion
                    ))
                }
                if scopePhrases.contains(where: { text.contains($0) }),
                   containsRepositoryPath(text) {
                    findings.append(.scopeCriterion(
                        childPosition: childIndex + 1, childTitle: child.title,
                        criterionPosition: criterionIndex + 1, criterionText: criterion
                    ))
                }
            }

            // Earlier-only edges form a DAG, so their ancestors are already available.
            var earlierChildren: Set<Int> = []
            for position in child.after ?? [] where position >= 1 && position <= childIndex {
                let earlierIndex = position - 1
                earlierChildren.insert(earlierIndex)
                earlierChildren.formUnion(ancestors[earlierIndex])
            }
            ancestors.append(earlierChildren)
        }

        for firstIndex in children.indices {
            for secondIndex in children.indices.dropFirst(firstIndex + 1) {
                guard !ancestors[secondIndex].contains(firstIndex) else { continue }
                let shared = components[firstIndex].intersection(components[secondIndex]).sorted()
                guard !shared.isEmpty else { continue }
                findings.append(.unorderedOverlap(
                    firstChildPosition: firstIndex + 1, firstChildTitle: children[firstIndex].title,
                    secondChildPosition: secondIndex + 1, secondChildTitle: children[secondIndex].title,
                    sharedComponents: shared
                ))
            }
        }
        return findings
    }

    private static func containsRepositoryPath(_ text: String) -> Bool {
        let leadingDelimiters = "\"'`([{<"
        let trailingDelimiters = "\"'`)]}>,;:!?."
        return text.split(whereSeparator: { $0.isWhitespace }).contains { rawToken in
            guard !rawToken.contains("://") else { return false }
            var token = rawToken.drop(while: { leadingDelimiters.contains($0) })
            while let last = token.last, trailingDelimiters.contains(last) {
                token = token.dropLast()
            }
            if token.contains("/") { return true }
            if token.hasPrefix("."), token.count > 1 {
                return true
            }
            guard let dot = token.lastIndex(of: "."), dot != token.startIndex else { return false }
            let fileExtension = token[token.index(after: dot)...]
            return !fileExtension.isEmpty
        }
    }
}
