// Expected API: ChildProposal.integration: Bool? decodes the optional JSON "integration" mark;
// BreakdownChecker.check(_ children: [ChildProposal]) -> [BreakdownFinding]
// returns structural findings with actionable, 1-based child locations in .explanation.
// Existing BreakdownRequest.checkerFeedback and breakdownRetryRequested retain the rejected
// proposal/findings. Reconciler rejects persistent structural findings before adopting children
// or recording a preview, but still adopts proposals with only quality findings.
// All six criteria are behavioural; there are no source-only criteria to defer to review.
import Foundation
import Testing
@testable import AgentOSCore
import AgentOSTestSupport

@Suite struct GH_165Tests {
    @Test(arguments: InvalidShape.allCases)
    func eachInvalidIntegrationStructureNamesItsChildrenAndExplainsTheCorrection(
        shape: InvalidShape
    ) throws {
        let children = try Self.invalidProposal(shape)
        let findings = Self.structuralFindings(BreakdownChecker.check(children))
        try #require(!findings.isEmpty, "The integration structure must be reported, not silently accepted.")
        let relevant = findings.filter { finding in
            Self.matches(finding.explanation, shape.problemPattern)
        }
        try #require(!relevant.isEmpty, "Identify the structural problem: \(findings)")
        for finding in relevant {
            #expect(shape.positions.contains { position in
                Self.namesChild(finding.explanation, position: position, title: children[position - 1].title)
            }, "Each explanation must identify its own child's position and verbatim title.")
            #expect(Self.matches(finding.explanation, shape.correctionPattern),
                    "Explain how to correct this structure, not just that it is invalid.")
        }
        // Multiple marks may be reported together or separately for the extras after the first.
        let requiredPositions = shape == .multiple ? Array(shape.positions.dropFirst()) : shape.positions
        #expect(requiredPositions.allSatisfy { position in
            relevant.contains {
                Self.namesChild($0.explanation, position: position, title: children[position - 1].title)
            }
        }, "The findings together must identify every offending child.")
    }

    @Test(arguments: [false, true], [nil, [], [1], [2], [0, 4, 99]] as [[Int]?])
    func validIntegrationSuppressesOnlyItsOverlapsAndPreservesRepeatedCriteria(
        ordinaryOrdered: Bool, integrationAfter: [Int]?
    ) throws {
        let children = [
            try Self.child("Store record", criteria: ["A stored record can be retrieved."], touches: ["Shared"]),
            try Self.child("Read record", criteria: ["  A STORED record can be retrieved  "],
                           touches: ["Shared"], after: ordinaryOrdered ? [1] : nil),
            try Self.child("Combined flow", criteria: ["A stored record can be retrieved."],
                           touches: ["Shared"], after: integrationAfter, integration: true),
        ]
        let unmarked = BreakdownChecker.check(try Self.withoutMarks(children))
        let marked = BreakdownChecker.check(children)
        #expect(Self.structuralFindings(marked).isEmpty)
        let ordinaryOverlaps = Self.overlaps(unmarked).filter {
            if case .unorderedOverlap(_, _, let second, _, _) = $0 { return second != 3 }
            return false
        }
        #expect(Self.overlaps(marked) == ordinaryOverlaps)
        #expect(ordinaryOverlaps.count == (ordinaryOrdered ? 0 : 1))
        let expectedRepeated: [BreakdownFinding] = [
            .repeatedCriterion(childPositions: [1, 2, 3],
                               childTitles: children.map(\.title),
                               criterionText: "A stored record can be retrieved.")
        ]
        #expect(Self.repeated(marked) == expectedRepeated)
        #expect(Self.repeated(marked) == Self.repeated(unmarked))
    }

    @Test
    func validIntegrationKeepsTransitiveOrderingBetweenOrdinarySiblings() throws {
        let children = [
            try Self.child("Store", touches: ["Shared"]),
            try Self.child("Read", touches: ["Shared"], after: [1]),
            try Self.child("Display", touches: ["Shared"], after: [2]),
            try Self.child("Combined flow", touches: ["Shared"], integration: true),
        ]
        let marked = BreakdownChecker.check(children)
        let unmarked = BreakdownChecker.check(try Self.withoutMarks(children))
        #expect(Self.structuralFindings(marked).isEmpty)
        #expect(Self.overlaps(marked).isEmpty)
        #expect(Self.overlaps(unmarked).count == 3,
                "Only the unmarked final child is unordered; ordinary siblings are transitively ordered.")
    }

    @Test(arguments: InvalidShape.allCases)
    func invalidIntegrationStillGetsOrdinaryOverlapAndRepeatedCriterionChecks(
        shape: InvalidShape
    ) throws {
        var children = try Self.invalidProposal(shape)
        for index in children.indices {
            children[index].touches = ["Shared"]
            children[index].acceptanceCriteria = ["A stored record can be retrieved."]
        }
        let marked = BreakdownChecker.check(children)
        let unmarked = BreakdownChecker.check(try Self.withoutMarks(children))
        #expect(!Self.structuralFindings(marked).isEmpty)
        #expect(Self.overlaps(marked) == Self.overlaps(unmarked))
        #expect(Self.repeated(marked) == Self.repeated(unmarked))
        if children.count > 1 {
            #expect(!Self.overlaps(marked).isEmpty)
            #expect(!Self.repeated(marked).isEmpty)
        }
    }

    @Test(arguments: InvalidShape.allCases, [false, true])
    func structuralFirstProposalGetsOneRecordedRetryWithItsFindings(
        shape: InvalidShape, preview: Bool
    ) async throws {
        let first = try Self.invalidProposal(shape, prefix: "Initial ")
        let corrected = try Self.cleanProposal()
        let fixture = try Fixture(proposals: [first, corrected])
        try await Self.withFixture(fixture) {
            #expect(!Self.structuralFindings(BreakdownChecker.check(first)).isEmpty)
            if preview { try await fixture.preview() }
            else { try await fixture.breakDown() }
            try await Self.expectSingleRetry(fixture, first: first, second: corrected)
            let state = await fixture.ledger.workingState()
            if preview {
                let saved = try #require(state.previews[Self.ticket.key])
                #expect(saved.proposal.map(\.title) == corrected.map(\.title))
            } else {
                let root = try #require(state.node(forTicket: Self.ticket.key))
                #expect(root.phase == .split)
                #expect(root.children.compactMap { state.nodes[$0]?.spec.title } == corrected.map(\.title))
            }
        }
    }

    @Test(arguments: InvalidShape.allCases, [false, true])
    func persistentStructuralFindingsEscalateWithoutCreatingChildrenOrMakingALeaf(
        shape: InvalidShape, buildApproved: Bool
    ) async throws {
        let first = try Self.invalidProposal(shape, prefix: "Initial ")
        let second = try Self.invalidProposal(shape, prefix: "Retry ")
        let fixture = try Fixture(proposals: [first, second])
        try await Self.withFixture(fixture) {
            try await fixture.breakDown(buildApproved: buildApproved)
            let state = await fixture.ledger.workingState()
            let root = try #require(state.node(forTicket: Self.ticket.key))
            #expect(root.flags[.escalated] != nil)
            #expect(root.children.isEmpty)
            #expect(state.nodes.count == 1)
            #expect(root.spec.kind == .composite)
            #expect(root.phase != .split)
            #expect(await fixture.tracker.created.isEmpty)
            let records = await fixture.ledger.allRecords()
            #expect(!records.contains {
                if case .becameLeaf = $0.event.kind { return true }
                if case .phaseChanged(to: .split) = $0.event.kind { return true }
                if case .nodeCreated(let spec, _) = $0.event.kind { return spec.parent == root.id }
                return false
            }, "Rejection must happen before any split, child creation or leaf conversion.")
            let findings = Self.structuralFindings(BreakdownChecker.check(second))
            try #require(!findings.isEmpty)
            let comments = await fixture.tracker.comments
            #expect(comments.contains { text in
                findings.allSatisfy { text.contains($0.explanation) }
                    && Self.matches(text, #"(fix|edit|correct).{0,100}ticket.{0,120}harness:retry"#)
            }, "The escalation comment must list the retry's findings and explain how to resume.")
            #expect(comments.allSatisfy { !$0.contains("harness:go") },
                    "Invalid structure cannot be approved anyway.")
            try await Self.expectSingleRetry(fixture, first: first, second: second)
        }
    }

    @Test(arguments: InvalidShape.allCases)
    func persistentStructuralFindingsFailPreviewWithoutRecordingItOrCreatingAnything(
        shape: InvalidShape
    ) async throws {
        let first = try Self.invalidProposal(shape, prefix: "Initial ")
        let second = try Self.invalidProposal(shape, prefix: "Retry ")
        let fixture = try Fixture(proposals: [first, second])
        try await Self.withFixture(fixture) {
            try await fixture.preview()
            let state = await fixture.ledger.workingState()
            #expect(state.previews[Self.ticket.key] == nil)
            #expect(state.nodes.isEmpty)
            #expect(await fixture.tracker.created.isEmpty)
            let records = await fixture.ledger.allRecords()
            #expect(!records.contains {
                if case .previewRecorded(let ticket, _, _, _) = $0.event.kind {
                    return ticket == Self.ticket.key
                }
                return false
            })
            #expect(records.contains {
                if case .previewFinished(let ticket, _, let outcome) = $0.event.kind {
                    return ticket == Self.ticket.key && Self.matches(outcome, #"fail"#)
                }
                return false
            })
            let findings = Self.structuralFindings(BreakdownChecker.check(second))
            try #require(!findings.isEmpty)
            let comments = await fixture.tracker.comments
            #expect(comments.contains { text in
                findings.allSatisfy { text.contains($0.explanation) }
                    && Self.matches(text, #"preview.{0,120}fail|fail.{0,120}preview"#)
                    && Self.matches(text, #"nothing.{0,40}created|no.{0,40}(tickets|children).{0,40}created"#)
                    && Self.matches(text, #"(add|apply|use).{0,40}harness:preview.{0,40}again"#)
            }, "The failed preview must explain the findings, non-creation, and the preview-again signal.")
            #expect(comments.allSatisfy { !$0.contains("harness:go") })
            try await Self.expectSingleRetry(fixture, first: first, second: second)
        }
    }

    @Test(arguments: Quality.allCases, [false, true])
    func remainingQualityFindingsAreAdoptedIncludingWithAValidIntegrationChild(
        quality: Quality, integration: Bool
    ) async throws {
        let second = try Self.qualityProposal(quality, integration: integration)
        let findings = BreakdownChecker.check(second)
        #expect(Self.structuralFindings(findings).isEmpty)
        try #require(findings.contains { quality.matches($0) }, "The fixture must exercise this quality warning.")
        let fixture = try Fixture(proposals: [second, second])
        try await Self.withFixture(fixture) {
            try await fixture.breakDown(buildApproved: true)
            let state = await fixture.ledger.workingState()
            let root = try #require(state.node(forTicket: Self.ticket.key))
            #expect(root.phase == .split)
            #expect(root.flags[.escalated] == nil)
            #expect(root.children.count == second.count)
            #expect(await fixture.tracker.created.count == second.count)
            let specs = root.children.compactMap { state.nodes[$0]?.spec }
            #expect(specs.map(\.title) == second.map(\.title))
            #expect(specs.map(\.acceptanceCriteria) == second.map(\.acceptanceCriteria))
            try await Self.expectSingleRetry(fixture, first: second, second: second)
        }
    }

    @Test(arguments: Quality.allCases)
    func aStructuralRetryIsAdoptedOnceOnlyQualityFindingsRemain(quality: Quality) async throws {
        let first = try Self.invalidProposal(.notLast, prefix: "Initial ")
        let second = try Self.qualityProposal(quality, integration: true)
        let fixture = try Fixture(proposals: [first, second])
        try await Self.withFixture(fixture) {
            try await fixture.breakDown(buildApproved: true)
            let state = await fixture.ledger.workingState()
            let root = try #require(state.node(forTicket: Self.ticket.key))
            #expect(root.phase == .split)
            #expect(root.flags[.escalated] == nil)
            #expect(root.children.compactMap { state.nodes[$0]?.spec.title } == second.map(\.title))
            #expect(await fixture.tracker.created.count == second.count)
            try await Self.expectSingleRetry(fixture, first: first, second: second)
        }
    }

    @Test(arguments: Quality.allCases, [false, true])
    func remainingQualityFindingsRecordAPreviewWithoutCreatingAnything(
        quality: Quality, integration: Bool
    ) async throws {
        let first = try Self.invalidProposal(.notLast, prefix: "Initial ")
        let second = try Self.qualityProposal(quality, integration: integration)
        let findings = BreakdownChecker.check(second)
        #expect(Self.structuralFindings(findings).isEmpty)
        try #require(findings.contains { quality.matches($0) }, "The fixture must exercise this quality warning.")
        let fixture = try Fixture(proposals: [first, second])
        try await Self.withFixture(fixture) {
            try await fixture.preview()
            let state = await fixture.ledger.workingState()
            let preview = try #require(state.previews[Self.ticket.key])
            #expect(preview.proposal.map(\.title) == second.map(\.title))
            #expect(preview.proposal.map(\.acceptanceCriteria) == second.map(\.acceptanceCriteria))
            #expect(state.nodes.isEmpty)
            #expect(await fixture.tracker.created.isEmpty)
            let records = await fixture.ledger.allRecords()
            #expect(records.contains {
                if case .previewRecorded(let ticket, _, _, _) = $0.event.kind {
                    return ticket == Self.ticket.key
                }
                return false
            })
            let comments = await fixture.tracker.comments
            #expect(comments.allSatisfy {
                !Self.matches($0, #"preview.{0,120}fail|fail.{0,120}preview"#)
            }, "Quality warnings must not produce a preview-failed comment.")
            try await Self.expectSingleRetry(fixture, first: first, second: second)
        }
    }

    @Test
    func childLocationMatcherRecognizesExistingFindingsAndRejectsUnrelatedNumbers() throws {
        let children = [
            try Self.child("Store"),
            try Self.child("Combined flow", criteria: ["Read according to the existing rule."])
        ]
        let finding = try #require(BreakdownChecker.check(children).first)
        #expect(Self.namesChild(finding.explanation, position: 2, title: "Combined flow"))
        #expect(!Self.namesChild(finding.explanation, position: 1, title: "Combined flow"))
        #expect(!Self.namesChild("Combined flow needs at least 2 other children.",
                                position: 2, title: "Combined flow"))
        #expect(Self.namesChild("Integration child at position 3 \"Combined flow\" must be last.",
                               position: 3, title: "Combined flow"))
        #expect(!Self.namesChild("Integration children need at least 2 \"Combined flow\" observations.",
                                position: 2, title: "Combined flow"))
        let aggregate = BreakdownFinding.repeatedCriterion(
            childPositions: [3, 4], childTitles: ["Combined flow", "Combined audit"],
            criterionText: "Retrieve a record.")
        #expect(Self.namesChild(aggregate.explanation, position: 3, title: "Combined flow"))
        #expect(Self.namesChild(aggregate.explanation, position: 4, title: "Combined audit"))
        #expect(!Self.namesChild(aggregate.explanation, position: 4, title: "Combined flow"))
        #expect(!Self.matches("Child 2 \"Combined flow\" needs two other children. Add a criterion.",
                             InvalidShape.oneOther.correctionPattern))
        #expect(Self.matches("Child 2 \"Combined flow\" has only one other child. Add another ordinary child.",
                             InvalidShape.oneOther.correctionPattern))
        #expect(Self.matches("Child 1 \"Combined flow\" is not last. Move it to the last position.",
                             InvalidShape.notLast.correctionPattern))
        #expect(Self.matches("Child 4 \"Combined audit\" is a second integration child. Keep only one integration child.",
                             InvalidShape.multiple.correctionPattern))
        #expect(Self.matches("Child 1 \"Combined flow\" is a lone integration proposal. Add at least two ordinary children.",
                             InvalidShape.lone.correctionPattern))
        #expect(!Self.matches("Child 1 \"Combined flow\" is not last. Move a log entry. The last child is fine.",
                             InvalidShape.notLast.correctionPattern))
        #expect(!Self.matches("Child 4 \"Combined audit\" is a second integration child. Remove a log entry. Clear documentation about the integration flag.",
                             InvalidShape.multiple.correctionPattern))
    }

    @Test
    func unmarkedCleanProposalProvesTheFixtureCanCreateChildrenWithoutARetry() async throws {
        let children = try Self.cleanProposal()
        #expect(BreakdownChecker.check(children).isEmpty)
        let fixture = try Fixture(proposals: [children])
        try await Self.withFixture(fixture) {
            try await fixture.breakDown()
            let state = await fixture.ledger.workingState()
            let root = try #require(state.node(forTicket: Self.ticket.key))
            #expect(root.phase == .split)
            #expect(root.children.count == 2)
            #expect(await fixture.tracker.created.count == 2)
            #expect(await fixture.decomposer.requests.count == 1)
            #expect(!(await fixture.ledger.allRecords()).contains {
                if case .breakdownRetryRequested = $0.event.kind { return true }
                return false
            })
        }
    }
}
