// API: a human's EventKind.testUpdatesApproved(tests: [String]) records the node's approved tests.
// Reconciler passes those approvals to CopilotTestAuthor.prompt(for:) and CopilotReviewer.prompt(for:).
// Existing authorTests, preCheck, AgentReport.updatedTests and otherTestsUpdated provide the observable contract.
// Source-only criteria: AC3's single AgentOSCore rule and both callers; AC6's documentation changes.

@testable import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_144Tests {
    @Test(arguments: [false, true])
    func theTestAuthorSeesApprovalsAndTheCriterionExceptionIncludingForDrafts(draft: Bool) async throws {
        let fixture = try await Fixture(approved: [Fixture.older, Fixture.unit])
        defer { fixture.cleanUp() }
        let node = try #require(await fixture.node())
        let task = await fixture.reconciler.makeTask(
            node, run: "author", in: fixture.root, log: nil, for: .testAuthor,
            unfinishedWork: draft ? [Fixture.older] : []
        )

        let instructions = CopilotTestAuthor.prompt(for: task)
        #expect(instructions.contains(Fixture.older))
        #expect(instructions.contains(Fixture.unit))
        #expect(instructions.lowercased().contains("approved"))
        #expect(Self.allowsApprovalWithoutACriterion(instructions),
                "Approved tests may be updated where this change requires it, without a naming criterion")
        #expect(Self.requiresACriterionForUnapprovedTests(instructions),
                "Unapproved tests must still need a criterion; approval is not a blanket test-edit permission")
        #expect(instructions.contains("updatedTests"))
    }

    @Test
    func anApprovedListedUpdateWithoutANamingCriterionIsCommittedAndLocked() async throws {
        let fixture = try await Fixture(
            approved: [Fixture.older, Fixture.unit],
            edits: [Fixture.older: "expects hello\n", Fixture.unit: "also expects hello\n"],
            reported: [Fixture.older, Fixture.unit]
        )
        defer { fixture.cleanUp() }

        try await fixture.authorTests()

        let node = try #require(await fixture.node())
        #expect(node.phase == .ready)
        #expect(Set(node.updatedOtherTests) == Set([Fixture.older, Fixture.unit]))
        #expect(try await fixture.workspace.committedText(at: Fixture.older) == "expects hello\n")
        #expect(try await fixture.workspace.committedText(at: Fixture.unit) == "also expects hello\n")
        let records = await fixture.ledger.records(for: node.id)
        #expect(records.contains {
            guard case .otherTestsUpdated(let files, let digest) = $0.event.kind,
                  case .agent(_, .testAuthor) = $0.event.by else { return false }
            return Set(files) == Set([Fixture.older, Fixture.unit])
                && digest == Hashing.digest(ofFiles: files, in: fixture.root)
        })

        try await fixture.submitAndPreCheck()

        let checked = try #require(await fixture.node())
        #expect(checked.evidence.last?.passed == true,
                "The shared rule must let verification accept intact test-author updates")
        #expect(await fixture.checks.calls == 1)
    }

    @Test(arguments: [Fixture.outside, Fixture.protectedFile, Fixture.protectedFolderFile])
    func approvalCannotKeepTestsOutsideUpdatableAreasOrInProtectedPaths(path: String) async throws {
        let fixture = try await Fixture(
            approved: [path], edits: [path: "changed expectation\n"], reported: [path]
        )
        defer { fixture.cleanUp() }

        try await fixture.authorTests()

        let node = try #require(await fixture.node())
        #expect(node.phase == .ready)
        #expect(!node.updatedOtherTests.contains(path))
        #expect(try await !fixture.workspace.changedFiles(in: fixture.root).contains(path))
        #expect(try await fixture.workspace.committedText(at: path) == Fixture.original)
        #expect(await fixture.ledger.records(for: node.id).allSatisfy {
            guard case .otherTestsUpdated(let files, _) = $0.event.kind else { return true }
            return !files.contains(path)
        })
    }

    @Test
    func anApprovedTestMustStillBeListedInUpdatedTestsToBeKept() async throws {
        let fixture = try await Fixture(
            approved: [Fixture.older], edits: [Fixture.older: "changed expectation\n"], reported: []
        )
        defer { fixture.cleanUp() }

        try await fixture.authorTests()

        let node = try #require(await fixture.node())
        #expect(node.phase == .ready)
        #expect(!node.updatedOtherTests.contains(Fixture.older))
        #expect(try await fixture.workspace.committedText(at: Fixture.older) == Fixture.original)
    }

    @Test(arguments: [false, true])
    func anImplementerCannotChangeAnApprovedTestWhetherOrNotTheAuthorUpdatedIt(authorUpdated: Bool) async throws {
        let fixture = try await Fixture(
            approved: [Fixture.older],
            edits: authorUpdated ? [Fixture.older: "expects hello\n"] : [:],
            reported: authorUpdated ? [Fixture.older] : []
        )
        defer { fixture.cleanUp() }
        try await fixture.authorTests()
        try Self.write("weakened by implementer\n", to: Fixture.older, in: fixture.root)

        try await fixture.submitAndPreCheck()

        let node = try #require(await fixture.node())
        let failure = try #require(node.evidence.last)
        let expected = authorUpdated
            ? "Other work's tests the acceptance tests updated were changed afterwards (not allowed)"
            : "Changed other nodes' tests (not allowed)"
        #expect(!failure.passed)
        #expect(failure.summary == "\(expected): \(Fixture.older)")
        #expect(node.phase != .landing && node.phase != .proven)
        #expect(await fixture.checks.calls == 0,
                "Changing an approved test is rejected before the test runner can report success")
    }

    @Test(arguments: [ReviewStage.acceptanceTests, .change])
    func reviewersSeeEachChangedApprovedTestAndTheStageSpecificInstructions(stage: ReviewStage) async throws {
        let edits = [Fixture.older: "expects hello\n", Fixture.unit: "also expects hello\n"]
        let reported = [Fixture.older, Fixture.unit]
        let criteria = reported.map { "Update \($0) to expect hello instead of hi" }
        let fixture = try await Fixture(
            approved: [Fixture.older, Fixture.unit, Fixture.unchanged],
            edits: edits, reported: reported, criteria: criteria
        )
        defer { fixture.cleanUp() }
        let unapproved = try await Fixture(edits: edits, reported: reported, criteria: criteria)
        defer { unapproved.cleanUp() }
        try await fixture.authorTests()
        try await unapproved.authorTests()
        let request = try await fixture.reviewRequest(stage: stage)
        let control = try await unapproved.reviewRequest(stage: stage)
        #expect(request.context.fullDiff == control.context.fullDiff,
                "Both reviews must see the same diff so its paths cannot count as added approval guidance")

        let prompt = CopilotReviewer.prompt(for: request)
        let added = Self.addedGuidance(in: prompt, comparedTo: CopilotReviewer.prompt(for: control))
        #expect(added.contains(Fixture.older),
                "List the changed approval explicitly, not just among generic diff or acceptance-test data")
        #expect(added.contains(Fixture.unit))
        #expect(!added.contains(Fixture.unchanged),
                "Only approved tests the branch changed belong in the added review guidance")
        #expect(added.lowercased().contains("approved"))
        if stage == .change {
            #expect(added.lowercased().contains("weaken"))
            #expect(added.lowercased().contains("remov"))
            #expect(added.lowercased().contains("finding"))
        } else {
            #expect(Self.allowsApprovalWithoutACriterion(added),
                    "Acceptance-test review must not reject an approved update for lacking a naming criterion")
            #expect(added.lowercased().contains("scope"))
        }
    }

    @Test
    func theFixturePreservesExistingCriterionBasedUpdatesAndRunsTheirPreCheck() async throws {
        let fixture = try await Fixture(
            edits: [Fixture.older: "expects hello\n"], reported: [Fixture.older],
            criteria: ["Update \(Fixture.older) to expect hello instead of hi"]
        )
        defer { fixture.cleanUp() }

        try await fixture.authorTests()
        try await fixture.submitAndPreCheck()

        let node = try #require(await fixture.node())
        #expect(node.phase == .landing)
        #expect(node.updatedOtherTests.contains(Fixture.older))
        #expect(try await fixture.workspace.committedText(at: Fixture.older) == "expects hello\n")
        #expect(try await fixture.workspace.committedText(at: Fixture.own) == Fixture.ownContents)
        #expect(node.evidence.last?.passed == true)
        #expect(await fixture.checks.calls == 1)

        let change = try await fixture.reviewRequest(stage: .change)
        let tests = try await fixture.reviewRequest(stage: .acceptanceTests)
        let guidance = Self.addedGuidance(
            in: CopilotReviewer.prompt(for: change), comparedTo: CopilotReviewer.prompt(for: tests)
        )
        #expect(guidance.contains("Independently review the change."),
                "Check the prompt-difference helper against an existing stage-specific instruction")
        #expect(Self.allowsApprovalWithoutACriterion(
            "Approved tests may be updated whether or not a criterion names them."
        ))
        #expect(Self.requiresACriterionForUnapprovedTests(
            "Tests not approved remain restricted. A ticket criterion must require their update."
        ))
    }

    private static func addedGuidance(in prompt: String, comparedTo control: String) -> String {
        // The same diff already lists these paths; approvals must add their own listing.
        prompt.components(separatedBy: "\n").difference(from: control.components(separatedBy: "\n"))
            .compactMap { change -> String? in
                guard case .insert(_, let line, _) = change else { return nil }
                return line
            }.joined(separator: "\n")
    }

    private static func allowsApprovalWithoutACriterion(_ text: String) -> Bool {
        let text = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.contains("approved") && text.contains("criteri") && [
            "even", "without", "whether", "regardless", "irrespective",
            "need not", "not required", "not necessary", "no requirement", "no need",
            "does not need", "do not need", "doesn't need", "don't need",
            "no criterion", "no criteria",
        ].contains(where: text.contains)
    }

    private static func requiresACriterionForUnapprovedTests(_ text: String) -> Bool {
        let text = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limitsUnapprovedTests = [
            "unapproved", "not approved", "aren't approved", "are not approved",
            "not on the approved", "not in the approved", "outside the approved",
            "other tests", "otherwise", "all remaining tests",
        ].contains(where: text.contains)
        let requires = ["requir", "need", "must", "only", "still"].contains(where: text.contains)
        return limitsUnapprovedTests && text.contains("criteri") && requires
    }

    static func write(_ text: String, to path: String, in directory: URL) throws {
        let file = directory.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}
