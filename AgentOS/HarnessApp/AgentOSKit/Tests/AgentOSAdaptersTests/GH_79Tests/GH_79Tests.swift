// Expected API: NodeSpec.predictedPaths: [String], NodeState.actualChangedFiles: [String]?,
// Policy.avoidOverlappingWork: Bool, EventKind.actualChangedFilesRecorded(files: [String]),
// and EventKind.predictedPathsExpanded(files: [String]).
// Reconciler records Workspace.changedFiles(in:)
// on submission, clears actual files on rework, and durably expands predictions on landing
// conflicts. Existing ledger replay, scheduling, and the work pane expose those changes.
// Missing predictions use an empty array, including for legacy leaves.
// Reviewer-only criterion: docs/real-repo-mode.md describes actual files replacing
// predictions after submission and conflict files being added to predictions.
import Foundation
import SwiftUI
import Testing
import AgentOSCore
import AgentOSUI
import AgentOSTestSupport

@Suite(.timeLimit(.minutes(1)))
struct GH_79Tests {
    @Test
    func implementerSubmissionRecordsTheWholeBranchDiffAndReplaysIt() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let files = ["Sources/Added.swift", "Sources/Removed.swift", "Assets/File with spaces.json"]
        let spec = try await fixture.leaf(
            "GH-79-A", predictions: ["Sources/Predicted.swift"], implementations: [files]
        )

        let submitted = try await fixture.until { $0.nodes[spec.id]?.lastSubmission != nil }
        let node = try #require(submitted.nodes[spec.id])
        let expected = Set(files + [fixture.workspace.testFolder(for: spec) + "/Acceptance.swift"])
        #expect(node.actualChangedFiles != nil)
        #expect(Set(node.actualChangedFiles ?? []) == expected)
        #expect(await fixture.workspace.diffQueries.contains(fixture.workspace.worktree(for: spec.id)))

        let replay = try Self.replay(await fixture.ledger.allRecords())
        #expect(Set(await replay.workingState().nodes[spec.id]?.actualChangedFiles ?? []) == expected)
        #expect(await replay.verifyChain().isIntact)
    }

    @Test
    func anAlreadySatisfiedSubmissionRecordsAKnownEmptyDiff() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let spec = try await fixture.leaf(
            "GH-79-EMPTY", predictions: ["Sources/Predicted.swift"],
            implementations: [[]], alreadySatisfied: true, includeTestInDiff: false
        )
        let state = try await fixture.until { $0.nodes[spec.id]?.lastSubmission != nil }
        #expect(state.nodes[spec.id]?.actualChangedFiles == [])

        let replay = try Self.replay(await fixture.ledger.allRecords())
        #expect(await replay.workingState().nodes[spec.id]?.actualChangedFiles == [])
    }

    @Test(arguments: [false, true], ProgressStage.allCases)
    func inProgressWorkUsesActualFilesInsteadOfPredictions(waiting: Bool, stage: ProgressStage) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let owner = try await fixture.leaf(
            "GH-79-OWNER", predictions: ["Sources/Forecast/"],
            implementations: [["Sources/Actual.swift"]]
        )
        _ = try await fixture.until { $0.nodes[owner.id]?.lastSubmission != nil }
        try await fixture.holdInProgress(owner, at: stage)
        try await fixture.workspace.setFiles(["Sources/Forecast/Feature.swift"], for: owner.id)
        let overlapping = try await fixture.leaf(
            "GH-79-HELD", predictions: ["Sources/Actual.swift"],
            implementations: [["Sources/HeldImplementation.swift"]]
        )
        let noLongerOverlapping = try await fixture.leaf(
            "GH-79-FREE", predictions: ["Sources/Forecast/Feature.swift"],
            implementations: [["Sources/FreeImplementation.swift"]]
        )

        _ = try await fixture.until(waiting: waiting) {
            $0.nodes[noLongerOverlapping.id]?.lastSubmission != nil
        }
        #expect(await fixture.workspace.starts(for: noLongerOverlapping.id) > 0)
        #expect(await fixture.workspace.starts(for: overlapping.id) == 0)

        try await fixture.finishInProgress(owner)
        _ = try await fixture.until(waiting: waiting) { $0.nodes[overlapping.id]?.lastSubmission != nil }
        #expect(await fixture.workspace.starts(for: overlapping.id) > 0)
    }

    @Test(arguments: [false, true])
    func aKnownEmptyActualDiffDoesNotFallBackToItsPrediction(waiting: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let owner = try await fixture.leaf(
            "GH-79-EMPTY", predictions: ["Sources/Forecast/"],
            implementations: [[]], touches: [], alreadySatisfied: true, includeTestInDiff: false
        )
        let submitted = try await fixture.until { $0.nodes[owner.id]?.lastSubmission != nil }
        #expect(submitted.nodes[owner.id]?.actualChangedFiles == [])
        try await fixture.holdInProgress(owner, at: .checking)
        let ready = try await fixture.leaf(
            "GH-79-FREE", predictions: ["Sources/Forecast/Feature.swift"],
            implementations: [["Sources/FreeImplementation.swift"]]
        )

        _ = try await fixture.until(waiting: waiting) { $0.nodes[ready.id]?.lastSubmission != nil }
        #expect(await fixture.workspace.starts(for: ready.id) > 0)
    }

    @Test
    func aConflictResetClearsActualFilesUntilTheNextSubmissionReplacesThem() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let spec = try await fixture.leaf(
            "GH-79-REWORK", predictions: ["Sources/Original.swift"],
            implementations: [["Sources/First.swift"], ["Sources/Second.swift"]]
        )
        try await fixture.conflict(spec, files: ["Sources/Unexpected.swift"])

        let afterConflict = await fixture.ledger.allRecords()
        let firstCommit = try #require(afterConflict.compactMap { record -> String? in
            guard record.event.node == spec.id,
                  case .changeSubmitted(_, let commit) = record.event.kind else { return nil }
            return commit
        }.first)
        let reset = try #require(afterConflict.first {
            guard $0.event.node == spec.id else { return false }
            if case .reworkNeeded = $0.event.kind { return true }
            return false
        })
        let beforeReset = try Self.replay(afterConflict.filter { $0.position < reset.position })
        let firstFiles = Set(["Sources/First.swift", fixture.workspace.testFolder(for: spec) + "/Acceptance.swift"])
        #expect(Set(await beforeReset.workingState().nodes[spec.id]?.actualChangedFiles ?? []) == firstFiles)
        let nextImplementation = afterConflict.first {
            guard $0.position > reset.position, $0.event.node == spec.id else { return false }
            if case .runStarted(_, .implementer) = $0.event.kind { return true }
            return false
        }
        let boundary = nextImplementation?.position ?? afterConflict.count
        let resetReplay = try Self.replay(afterConflict.filter { $0.position < boundary })
        let resetNode = try #require(await resetReplay.workingState().nodes[spec.id])
        #expect(resetNode.actualChangedFiles == nil)
        #expect(resetNode.lastSubmission == nil)

        let resubmitted = try await fixture.until {
            guard let submission = $0.nodes[spec.id]?.lastSubmission else { return false }
            return submission.commit != firstCommit
        }
        let expected = Set(["Sources/Second.swift", fixture.workspace.testFolder(for: spec) + "/Acceptance.swift"])
        #expect(Set(resubmitted.nodes[spec.id]?.actualChangedFiles ?? []) == expected)
        let replay = try Self.replay(await fixture.ledger.allRecords())
        #expect(Set(await replay.workingState().nodes[spec.id]?.actualChangedFiles ?? []) == expected)
    }

    @Test(arguments: PredictionShape.allCases)
    func aLandingConflictAppendsOnlyFilesNotAlreadyCoveredIncludingForLegacyLeaves(shape: PredictionShape) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let spec = try await fixture.leaf(
            "GH-79-CONFLICT", predictions: shape.paths, phase: .landing, buildAllowed: false
        )
        try await fixture.conflict(spec, files: Self.conflictingFiles)

        let node = try #require(await fixture.ledger.workingState().nodes[spec.id])
        let original = shape.paths ?? []
        let updated = node.spec.predictedPaths
        #expect(Array(updated.prefix(original.count)) == original)
        #expect(Set(updated.dropFirst(original.count)) == Set(shape.additions))
        #expect(updated.count == original.count + shape.additions.count)
        #expect(node.reworks == 1)
        #expect(await fixture.workspace.resets.contains(spec.id))
    }

    @Test
    func predictionExpansionIsALedgerEventWhoseSummaryListsItsFilesAndSurvivesReplay() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let original = ["Sources/Original.swift"]
        let added = ["Sources/Shared.swift", "Sources/Additional.swift"]
        let spec = try await fixture.leaf(
            "GH-79-AUDIT", predictions: original, phase: .landing, buildAllowed: false
        )
        let before = await fixture.ledger.allRecords().count
        try await fixture.conflict(spec, files: added)
        let records = await fixture.ledger.allRecords()
        var previousPaths = Set(original)
        var audited: Set<String> = []
        for record in records.dropFirst(before) {
            let replay = try Self.replay(Array(records.prefix(record.position + 1)))
            let paths = Set(await replay.workingState().nodes[spec.id]?.spec.predictedPaths ?? [])
            let expansion = paths.subtracting(previousPaths)
            for path in expansion {
                #expect(record.event.node == spec.id)
                #expect(record.event.kind.summary.contains(path))
            }
            audited.formUnion(expansion)
            previousPaths = paths
        }
        #expect(audited == Set(added))
        let replay = try Self.replay(records)
        #expect(Set(await replay.workingState().nodes[spec.id]?.spec.predictedPaths ?? []) == Set(original + added))
        #expect(await replay.verifyChain().isIntact)
    }

    @MainActor @Test
    func theWorkPanePathsRowShowsConflictFilesAfterLedgerReplay() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let spec = try await fixture.leaf(
            "GH-79-UI", predictions: ["Sources/Original.swift"], phase: .landing, buildAllowed: false
        )
        let model = HarnessViewModel()
        model.state = await fixture.ledger.workingState()
        let baseline = try #require(model.state.nodes[spec.id])
        let controlText = try RenderedUI.text(
            of: NodeDetail(node: baseline).environment(model), size: CGSize(width: 1100, height: 900)
        )
        try #require(RenderedUI.shows("Touches", in: controlText), "The shared renderer must read the existing detail grid.")
        try #require(RenderedUI.shows("Engine", in: controlText))

        let added = ["Sources/Shared.swift", "Sources/Additional.swift"]
        try await fixture.conflict(spec, files: added)
        let replay = try Self.replay(await fixture.ledger.allRecords())
        model.state = await replay.workingState()
        let node = try #require(model.state.nodes[spec.id])
        let text = try RenderedUI.text(
            of: NodeDetail(node: node).environment(model), size: CGSize(width: 1100, height: 900)
        )
        #expect(RenderedUI.shows("Paths", in: text))
        for path in ["Sources/Original.swift"] + added {
            #expect(RenderedUI.shows(path, in: text), "The Paths row should show \(path). Recognized text: \(text)")
        }
    }

    @Test(arguments: [false, true], [false, true])
    func aReworkedLeafWaitsForWorkChangingItsNewlyDiscoveredConflictFile(
        waiting: Bool, originallyHadPaths: Bool
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let reworked = try await fixture.leaf(
            "GH-79-REWORK", predictions: originallyHadPaths ? ["Sources/Original.swift"] : nil,
            implementations: [["Sources/ReworkedImplementation.swift"]], phase: .landing, buildAllowed: false
        )
        try await fixture.conflict(reworked, files: ["Sources/Shared.swift"])
        let owner = try await fixture.leaf(
            "GH-79-OWNER", predictions: ["Sources/WrongPrediction.swift"],
            implementations: [["Sources/Shared.swift"]], touches: ["Storage"]
        )
        _ = try await fixture.until { $0.nodes[owner.id]?.lastSubmission != nil }
        try await fixture.holdInProgress(owner, at: .checking)
        try await fixture.openBuildGate(reworked)
        let independent = try await fixture.leaf(
            "GH-79-INDEPENDENT", predictions: ["Sources/Independent.swift"],
            implementations: [["Sources/Independent.swift"]]
        )

        _ = try await fixture.until(waiting: waiting) { $0.nodes[independent.id]?.lastSubmission != nil }
        #expect(await fixture.workspace.starts(for: independent.id) > 0)
        #expect(await fixture.workspace.starts(for: reworked.id) == 0)

        try await fixture.finishInProgress(owner)
        _ = try await fixture.until(waiting: waiting) { $0.nodes[reworked.id]?.lastSubmission != nil }
        #expect(await fixture.workspace.starts(for: reworked.id) > 0)
    }

    @Test(arguments: PredictionShape.allCases)
    func aLandingConflictWithoutFileNamesLeavesPredictionsUnchanged(shape: PredictionShape) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let spec = try await fixture.leaf(
            "GH-79-NO-FILES", predictions: shape.paths, phase: .landing, buildAllowed: false
        )
        try await fixture.conflict(spec, files: [])
        #expect(await fixture.ledger.workingState().nodes[spec.id]?.spec.predictedPaths == (shape.paths ?? []))
        let replay = try Self.replay(await fixture.ledger.allRecords())
        #expect(await replay.workingState().nodes[spec.id]?.spec.predictedPaths == (shape.paths ?? []))
        #expect(await replay.workingState().nodes[spec.id]?.reworks == 1)
    }

}
