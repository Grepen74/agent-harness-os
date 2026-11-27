/// Problems in a proposed breakdown, with 1-based proposal and criterion positions.
public enum BreakdownFinding: Codable, Hashable, Sendable {
    case vagueReference(childPosition: Int, childTitle: String,
                        criterionPosition: Int, criterionText: String)
    case scopeCriterion(childPosition: Int, childTitle: String,
                        criterionPosition: Int, criterionText: String)
    case unorderedOverlap(firstChildPosition: Int, firstChildTitle: String,
                          secondChildPosition: Int, secondChildTitle: String,
                          sharedComponents: [String])
    /// More criteria than one agent run reliably proves: such leaves time out and keep coming back from review.
    case tooManyCriteria(childPosition: Int, childTitle: String, count: Int, limit: Int)
    /// The same criterion in several children: each of their test authors tests it again.
    case repeatedCriterion(childPositions: [Int], childTitles: [String], criterionText: String)
    case multipleIntegrationChildren(childPosition: Int, childTitle: String)
    case integrationChildNotLast(childPosition: Int, childTitle: String)
    case integrationChildWithOneSibling(childPosition: Int, childTitle: String)
    case loneIntegrationChild(childPosition: Int, childTitle: String)

    public var severity: Finding.Severity {
        switch self {
        case .multipleIntegrationChildren, .integrationChildNotLast,
             .integrationChildWithOneSibling, .loneIntegrationChild:
            .blocker
        case .vagueReference, .scopeCriterion, .unorderedOverlap, .tooManyCriteria, .repeatedCriterion:
            .warning
        }
    }
}

/// Checks proposal values without changing them or consulting external state.
public enum BreakdownChecker {
    private static let vaguePhrases = [
        "existing rule", "as agreed", "same as", "as before", "the agreed", "see child"
    ]
    private static let scopePhrases = ["doesn't change", "does not change", "unchanged"]
    public static let maxCriteriaPerChild = 6

    public static func check(_ children: [ChildProposal]) -> [BreakdownFinding] {
        var findings: [BreakdownFinding] = []
        var ancestors: [Set<Int>] = []
        let integrationIndices = children.indices.filter { children[$0].integration == true }
        let validIntegrationIndex = integrationIndices.count == 1 && children.count >= 3
            && integrationIndices.first == children.indices.last ? integrationIndices.first : nil
        let components = children.map { child in
            Set((child.touches ?? []).map { ComponentName.from($0) })
        }

        for (childIndex, child) in children.enumerated() {
            if child.integration == true {
                if integrationIndices.count > 1 {
                    findings.append(.multipleIntegrationChildren(childPosition: childIndex + 1, childTitle: child.title))
                }
                if childIndex != children.indices.last {
                    findings.append(.integrationChildNotLast(childPosition: childIndex + 1, childTitle: child.title))
                }
                if children.count == 2 {
                    findings.append(.integrationChildWithOneSibling(childPosition: childIndex + 1, childTitle: child.title))
                } else if children.count == 1 {
                    findings.append(.loneIntegrationChild(childPosition: childIndex + 1, childTitle: child.title))
                }
            }
            if child.acceptanceCriteria.count > maxCriteriaPerChild {
                findings.append(.tooManyCriteria(childPosition: childIndex + 1, childTitle: child.title,
                                                 count: child.acceptanceCriteria.count, limit: maxCriteriaPerChild))
            }
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

        var childrenByCriterion: [String: [Int]] = [:]
        var criterionOrder: [String] = []
        for (childIndex, child) in children.enumerated() {
            var seenInChild: Set<String> = []
            for criterion in child.acceptanceCriteria.map(normalized)
            where !criterion.isEmpty && seenInChild.insert(criterion).inserted {
                if childrenByCriterion[criterion] == nil { criterionOrder.append(criterion) }
                childrenByCriterion[criterion, default: []].append(childIndex)
            }
        }
        for criterion in criterionOrder {
            let indices = childrenByCriterion[criterion, default: []]
            guard indices.count > 1,
                  let text = children[indices[0]].acceptanceCriteria.first(where: { normalized($0) == criterion }) else { continue }
            findings.append(.repeatedCriterion(childPositions: indices.map { $0 + 1 },
                                               childTitles: indices.map { children[$0].title }, criterionText: text))
        }

        for firstIndex in children.indices {
            for secondIndex in children.indices.dropFirst(firstIndex + 1) {
                guard secondIndex != validIntegrationIndex else { continue }
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

    /// Case, spacing and a closing full stop don't make criteria different.
    private static func normalized(_ criterion: String) -> String {
        var text = criterion.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while text.hasSuffix(".") { text.removeLast() }
        return text
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
