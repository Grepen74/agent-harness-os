// Expected API: AgentOSCore.BreakdownChecker.check(_:) synchronously checks [ChildProposal]
// without I/O and returns [BreakdownFinding]. Equatable, Sendable findings carry 1-based
// child/criterion positions and verbatim titles/text, or both children and normalized components.
// Cases are vagueReference, scopeCriterion, and unorderedOverlap; severity uses Finding.Severity.
import Testing
import AgentOSCore

@Suite struct GH_64Tests {
    @Test
    func theCoreCheckerAcceptsOnlyProposalValuesAndReturnsStructuredFindings() {
        let check: ([ChildProposal]) -> [BreakdownFinding] = BreakdownChecker.check
        #expect(check([]).isEmpty)
        #expect(check([
            child("Explicit rule", criteria: ["A request with no identifier returns an error."])
        ]).isEmpty)
        #expect(check([
            child("Consumer", criteria: ["Apply the existing rule."])
        ]) == [
            vague(1, "Consumer", 1, "Apply the existing rule.")
        ])
    }

    @Test(arguments: [
        "existing rule", "as agreed", "same as", "as before", "the agreed", "see child",
        "ExIsTiNg RuLe", "As AgReEd", "SaMe As", "aS BeFoRe", "ThE AgReEd", "SeE ChIlD"
    ])
    func everyLiteralVaguePhraseIdentifiesItsChildAndCompleteCriterion(phrase: String) {
        let criterion = "  Output follows \(phrase), including all validation details.  "
        let proposals = [
            child("Unrelated", criteria: ["Return a documented error."]),
            child("Rule consumer", criteria: ["Return JSON.", criterion])
        ]
        #expect(BreakdownChecker.check(proposals) == [
            vague(2, "Rule consumer", 2, criterion)
        ])
    }

    @Test(arguments: [
        "", "Use the existing validation algorithm stated here: reject missing identifiers.",
        "An agreedness flag is true.", "Use the same result.",
        "The UI is as responsive as required.", "See the child documentation.",
        "Use existing  rule.", "Use as\nagreed."
    ])
    func nonmatchingTextDoesNotProduceVagueReferences(criterion: String) {
        #expect(BreakdownChecker.check([child("Explicit", criteria: [criterion])]).isEmpty)
    }

    @Test
    func literalMatchingDoesNotRequireWordBoundaries() {
        let criterion = "The agreedness flag is true."
        #expect(BreakdownChecker.check([child("Literal match", criteria: [criterion])]) == [
            vague(1, "Literal match", 1, criterion)
        ])
    }

    @Test
    func everyScopeFormAndPathCategoryIdentifiesItsChildAndCompleteCriterion() {
        let forms = ["doesn't change", "does not change", "unchanged",
                     "DoEsN't ChAnGe", "DoEs NoT ChAnGe", "UnChAnGeD"]
        let paths = ["Sources/Core", "README.md", ".gitignore", ".env"]
        for form in forms {
            for path in paths {
                let criterion = "  The implementation \(form) \(path)  "
                #expect(BreakdownChecker.check([
                    child("First", criteria: ["Return a value."]),
                    child("Scope claim", criteria: ["Reject invalid input.", criterion])
                ]) == [
                    scope(2, "Scope claim", 2, criterion)
                ])
            }
        }
    }

    @Test(arguments: [
        "The behavior doesn't change.",
        "The API does not change output.",
        "The result is unchanged.",
        "Update Sources/Core.",
        "Read README.md.",
        "Load .gitignore.",
        "The implementation does not modify README.md.",
        "The implementation doesn't change https://example.com/repo/file.swift",
        "The implementation does not change http://example.com/.env",
        "The implementation is unchanged ftp://example.com/path",
        "The implementation doesn't change custom://host/README.md"
    ])
    func aScopeFindingRequiresBothASupportedFormAndANonURLPath(criterion: String) {
        #expect(BreakdownChecker.check([child("Negative", criteria: [criterion])]).isEmpty)
    }

    @Test
    func aURLDoesNotHideASeparateRepositoryPathInTheSameCriterion() {
        let criterion = "See https://example.com/docs; README.md is unchanged"
        #expect(BreakdownChecker.check([child("Docs", criteria: [criterion])]) == [
            scope(1, "Docs", 1, criterion)
        ])
    }

    @Test
    func unorderedOverlapIncludesEverySharedNormalizedComponentOnce() {
        let firstTouches = ["weather service", "weather-service", "zeta", "123 engine", "only first"]
        let secondTouches = ["zeta", "weather_service", "123-engine", "only second", "zeta"]
        let shared = ["123 engine", "weather service", "zeta"].map {
            ComponentName.from($0)
        }.sorted()
        #expect(BreakdownChecker.check([
            child("Producer", touches: firstTouches),
            child("Consumer", touches: secondTouches)
        ]) == [
            overlap(1, "Producer", 2, "Consumer", shared)
        ])
    }

    @Test
    func normalizationUsesComponentNamesDefaultWordLimit() {
        let first = "one two three four producer"
        let second = "one-two-three-four-consumer"
        #expect(BreakdownChecker.check([
            child("Producer", touches: [first]),
            child("Consumer", touches: [second])
        ]) == [
            overlap(1, "Producer", 2, "Consumer", [ComponentName.from(first)])
        ])
    }

    @Test
    func onlyExplicitTouchListsCanCreateAnOverlap() {
        #expect(BreakdownChecker.check([
            child("Same title", touches: nil),
            child("Same title", touches: []),
            child("Same title", touches: ["same title"]),
            child("Other component", touches: ["different component"])
        ]).isEmpty)
        #expect(BreakdownChecker.check([
            child("Single child", touches: ["shared", "shared"])
        ]).isEmpty)
    }

    @Test
    func validDirectOrderSuppressesOverlapWithoutSuppressingCriterionFindings() {
        let criterion = "Apply the existing rule."
        #expect(BreakdownChecker.check([
            child("First", touches: ["shared"]),
            child("Second", criteria: [criterion], touches: ["shared"], after: [1])
        ]) == [
            vague(2, "Second", 1, criterion)
        ])
    }

    @Test
    func transitiveOrderThroughAChildWithoutSharedComponentsSuppressesOverlap() {
        #expect(BreakdownChecker.check([
            child("First", touches: ["shared"]),
            child("Bridge", touches: ["bridge"], after: [1]),
            child("Last", touches: ["shared"], after: [2])
        ]).isEmpty)
    }

    @Test(arguments: [-1, 0, 2, 3, 99])
    func selfLaterAndOutOfRangeReferencesCannotEstablishOrder(reference: Int) {
        #expect(BreakdownChecker.check([
            child("First", touches: ["shared"]),
            child("Second", touches: ["shared"], after: [reference]),
            child("Third", touches: ["unrelated"])
        ]) == [
            overlap(1, "First", 2, "Second", ["Shared"])
        ])
    }

    @Test
    func aLaterReferenceOnTheEarlierChildCannotOrderThePair() {
        #expect(BreakdownChecker.check([
            child("First", touches: ["shared"], after: [2]),
            child("Second", touches: ["shared"])
        ]) == [
            overlap(1, "First", 2, "Second", ["Shared"])
        ])
    }

    @Test
    func invalidEdgesCannotCompleteATransitiveOrderingPath() {
        #expect(BreakdownChecker.check([
            child("First", touches: ["shared"], after: [2]),
            child("Bridge", touches: ["bridge"]),
            child("Last", touches: ["shared"], after: [2])
        ]) == [
            overlap(1, "First", 3, "Last", ["Shared"])
        ])
    }

    @Test
    func invalidReferencesAndDuplicatesDoNotDiscardValidEarlierReferences() {
        #expect(BreakdownChecker.check([
            child("First", touches: ["shared"], after: [1, 3, 99]),
            child("Bridge", touches: ["bridge"], after: [1, 1, 0, 2, 3, 99]),
            child("Last", touches: ["shared"], after: [2, 2, -1, 3, 99])
        ]).isEmpty)
    }

    @Test
    func sharingAnEarlierDependencyDoesNotOrderTwoSiblings() {
        #expect(BreakdownChecker.check([
            child("Prerequisite", touches: ["base"]),
            child("Reader", touches: ["shared"], after: [1]),
            child("Writer", touches: ["shared"], after: [1])
        ]) == [
            overlap(2, "Reader", 3, "Writer", ["Shared"])
        ])
    }

    @Test
    func externalDependenciesAreNotSiblingAfterReferences() {
        let first = ChildProposal(title: "First", acceptanceCriteria: [], touches: ["shared"])
        let second = ChildProposal(title: "Second", acceptanceCriteria: [], touches: ["shared"],
                                   dependsOn: ["First"])
        #expect(BreakdownChecker.check([first, second]) == [
            overlap(1, "First", 2, "Second", ["Shared"])
        ])
    }

    @Test
    func statedOwnershipLeavesTheUnorderedOverlapAsAnAdvisoryWarning() throws {
        let findings = BreakdownChecker.check([
            child("Reader", criteria: ["Owns only the read methods."], touches: ["shared"]),
            child("Writer", criteria: ["Owns only the write methods."], touches: ["shared"])
        ])
        #expect(findings == [overlap(1, "Reader", 2, "Writer", ["Shared"])])
        let finding = try #require(findings.first)
        #expect(finding.severity == AgentOSCore.Finding.Severity.warning)
    }

    @Test
    func identicalCriterionTextAtDifferentPositionsRetainsEachFinding() {
        let text = "Apply the existing rule; README.md is unchanged"
        #expect(BreakdownChecker.check([
            child("Repeated", criteria: [text, text]),
            child("Repeated", criteria: [text])
        ]) == [
            vague(1, "Repeated", 1, text),
            scope(1, "Repeated", 1, text),
            vague(1, "Repeated", 2, text),
            scope(1, "Repeated", 2, text),
            vague(2, "Repeated", 1, text),
            scope(2, "Repeated", 1, text)
        ])
    }

    @Test
    func findingsAreDeduplicatedPerKindAndOrderedBeforeSortedChildPairs() {
        let both = "as agreed, use the existing rule; README.md doesn't change and is unchanged"
        let scopeOnly = "Sources/Core does not change; .env is unchanged"
        let vagueOnly = "see child; same as; as before; the agreed behavior"
        let proposals = [
            child("Duplicate title", criteria: ["Return a value.", both, scopeOnly],
                  touches: ["zeta", "alpha", "alpha"]),
            child("Duplicate title", criteria: [vagueOnly], touches: ["zeta", "alpha"]),
            child("Third", criteria: [both], touches: ["zeta", "alpha"])
        ]
        let expected: [BreakdownFinding] = [
            vague(1, "Duplicate title", 2, both),
            scope(1, "Duplicate title", 2, both),
            scope(1, "Duplicate title", 3, scopeOnly),
            vague(2, "Duplicate title", 1, vagueOnly),
            vague(3, "Third", 1, both),
            scope(3, "Third", 1, both),
            overlap(1, "Duplicate title", 2, "Duplicate title", ["Alpha", "Zeta"]),
            overlap(1, "Duplicate title", 3, "Third", ["Alpha", "Zeta"]),
            overlap(2, "Duplicate title", 3, "Third", ["Alpha", "Zeta"])
        ]
        #expect(BreakdownChecker.check(proposals) == expected)
        #expect(BreakdownChecker.check(proposals) == expected)
        var reorderedTouches = proposals
        for index in reorderedTouches.indices {
            reorderedTouches[index].touches = proposals[index].touches.map { Array($0.reversed()) }
        }
        #expect(BreakdownChecker.check(reorderedTouches) == expected)
    }

    private func child(_ title: String, criteria: [String] = [], touches: [String]? = nil,
                       after: [Int]? = nil) -> ChildProposal {
        ChildProposal(title: title, acceptanceCriteria: criteria, touches: touches, after: after)
    }

    private func vague(_ child: Int, _ title: String, _ criterion: Int,
                       _ text: String) -> BreakdownFinding {
        .vagueReference(childPosition: child, childTitle: title,
                        criterionPosition: criterion, criterionText: text)
    }

    private func scope(_ child: Int, _ title: String, _ criterion: Int,
                       _ text: String) -> BreakdownFinding {
        .scopeCriterion(childPosition: child, childTitle: title,
                        criterionPosition: criterion, criterionText: text)
    }

    private func overlap(_ first: Int, _ firstTitle: String, _ second: Int,
                         _ secondTitle: String, _ components: [String]) -> BreakdownFinding {
        .unorderedOverlap(firstChildPosition: first, firstChildTitle: firstTitle,
                          secondChildPosition: second, secondChildTitle: secondTitle,
                          sharedComponents: components)
    }
}
