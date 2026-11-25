// API contract: EventKind.testsRecorded(files: [String], suite: String) supplies the
// ledger's own-test record. Reconciler authoring/review use that record, falling back
// to Workspace.testFolder(for:) without one. SwiftAcceptanceTestPreflight accepts
// testFiles: [String]? alongside its existing testFolder argument (nil = legacy).
// Its rule findings and compiler classification accept the same optional file list.
// All six criteria describe observable behavior; none is source-only.

import AgentOSCore
import AgentOSAdapters
import AgentOSTestSupport
import Foundation
import Testing

@Suite
struct GH_150Tests {
    @Test(arguments: [true, false])
    func returnedTestsKeepTheirRecordedFilesOrLegacyFolderAndEarlierOtherTestUpdates(
        recorded: Bool
    ) async throws {
        let f = try await Fixture(recorded: recorded)
        defer { f.cleanUp() }
        await f.author.configure { task in
            let files = try Files.read(in: task.directory)
            for path in recorded ? Fixture.recordedFiles.filter({ $0 != Fixture.missing }) : [Fixture.legacy] {
                #expect(files[path] == f.branch[path], "Earlier own tests must reach the fresh worktree")
            }
            #expect(files[Fixture.other] == f.branch[Fixture.other])
            #expect(files[Fixture.production] == f.base[Fixture.production])
            if recorded {
                #expect(files[Fixture.legacy] == nil,
                        "A record keeps files, not everything in the old ticket folder")
            }
            try Files.write("func correctedAcceptance() {}\n", at: Fixture.newOwn, in: task.directory)
            return AgentReport()
        }

        try await f.authorAgain()

        let node = try await f.node()
        #expect(node.phase == .ready)
        #expect(node.flags[.escalated] == nil)
        #expect(node.updatedOtherTests.contains(Fixture.other),
                "Earlier other-test updates remain authorized without being listed again")
        #expect(await f.author.calls == 1)
    }

    @Test
    func rerunCommitsRecordedEditsAdditionsAndDeletionsAndDiscardsEverythingElse() async throws {
        let f = try await Fixture(recorded: true)
        defer { f.cleanUp() }
        await f.author.configure { task in
            try Files.write("func fixedRecordedTest() {}\n", at: Fixture.primary, in: task.directory)
            // Deleting an already missing file would not prove deletion survived the commit.
            if FileManager.default.fileExists(atPath: task.directory.appending(path: Fixture.deleted).path) {
                try FileManager.default.removeItem(at: task.directory.appending(path: Fixture.deleted))
            }
            try Files.write("func restoredRecordedHelper() {}\n", at: Fixture.missing, in: task.directory)
            try Files.write("func additionalOwnTest() {}\n", at: Fixture.newOwn, in: task.directory)
            try Files.write("func updatedOlderTest() {}\n", at: Fixture.other, in: task.directory)
            try Files.write("unapproved edit", at: Fixture.unapproved, in: task.directory)
            try Files.write("unrecorded sibling", at: Fixture.featureSibling, in: task.directory)
            try Files.write("lookalike folder", at: Fixture.lookalike, in: task.directory)
            try Files.write("placeholder implementation", at: Fixture.production, in: task.directory)
            return AgentReport(updatedTests: [Fixture.other, Fixture.production])
        }

        try await f.authorAgain()

        let committed = try #require(await f.workspace.committed)
        #expect(committed[Fixture.primary] == "func fixedRecordedTest() {}\n")
        #expect(committed[Fixture.deleted] == nil)
        #expect(committed[Fixture.missing] == "func restoredRecordedHelper() {}\n")
        #expect(committed[Fixture.newOwn] == "func additionalOwnTest() {}\n")
        #expect(committed[Fixture.other] == "func updatedOlderTest() {}\n")
        #expect(committed[Fixture.unapproved] == f.base[Fixture.unapproved])
        #expect(committed[Fixture.featureSibling] == nil)
        #expect(committed[Fixture.lookalike] == nil)
        #expect(committed[Fixture.production] == f.base[Fixture.production])
        #expect(try await f.node().phase == .ready,
                "Recorded paths outside the ticket folder are valid own-test changes")
    }

    @Test
    func recordedFilesListedInUpdatedTestsNeverBecomeOtherWorksTests() async throws {
        let f = try await Fixture(recorded: true)
        defer { f.cleanUp() }
        await f.author.configure { task in
            try Files.write("func correctedRecordedTest() {}\n", at: Fixture.primary, in: task.directory)
            try Files.write("func newOwnTest() {}\n", at: Fixture.newOwn, in: task.directory)
            try Files.write("func changedOtherTest() {}\n", at: Fixture.other, in: task.directory)
            return AgentReport(updatedTests: [Fixture.primary, Fixture.other])
        }

        try await f.authorAgain()

        let node = try await f.node()
        #expect(node.phase == .ready)
        #expect(node.updatedOtherTests.contains(Fixture.other))
        #expect(Set(node.updatedOtherTests).isDisjoint(with: Fixture.recordedFiles))
        let otherUpdates = await f.ledger.records(for: Fixture.id).compactMap { record -> [String]? in
            guard case .otherTestsUpdated(let files, _) = record.event.kind else { return nil }
            return files
        }
        #expect(otherUpdates.allSatisfy { Set($0).isDisjoint(with: Fixture.recordedFiles) })
    }

    @Test(arguments: [ReviewStage.acceptanceTests, .change])
    func bothReviewsShowEveryExistingRecordedFileInFullAndChangedOtherTestsByPath(
        stage: ReviewStage
    ) async throws {
        let f = try await Fixture(recorded: true)
        defer { f.cleanUp() }
        let changed = [Fixture.other, Fixture.legacy, Fixture.unapproved, Fixture.production]
        let request = try await f.review(stage, changed: changed)

        for path in Fixture.recordedFiles where path != Fixture.missing {
            #expect(request.acceptanceTests[path] == f.branch[path],
                    "Unchanged recorded tests still belong in the review")
        }
        #expect(request.acceptanceTests[Fixture.missing] == nil,
                "A deleted recorded helper must not prevent review of the remaining files")
        for path in changed where path != Fixture.production {
            #expect(request.acceptanceTests[path] == f.branch[path])
        }
        #expect(request.acceptanceTests[Fixture.production] == nil)
        let prompt = CopilotReviewer.prompt(for: request)
        #expect(prompt.contains(try #require(f.branch[Fixture.primary])))
        #expect(prompt.contains(try #require(f.branch[Fixture.deleted])))
        #expect(prompt.contains(Fixture.empty))
        for path in [Fixture.other, Fixture.legacy, Fixture.unapproved] {
            #expect(prompt.contains(path))
            #expect(!prompt.contains(try #require(f.branch[path])),
                    "Other work's tests are identified by path, not dumped in full")
        }
    }

    @Test
    func rerunPreflightReturnsRuleFindingsFromRecordedFilesOutsideTheLegacyFolder() async throws {
        let f = try await Fixture(recorded: true, preflight: SwiftAcceptanceTestPreflight())
        defer { f.cleanUp() }
        await f.author.configure { task in
            try Files.write("func badTest() async throws { try await Task.sleep(for: .seconds(1)) }\n",
                            at: Fixture.primary, in: task.directory)
            try Files.write("func extraOwnTest() {}\n", at: Fixture.newOwn, in: task.directory)
            return AgentReport(updatedTests: [Fixture.primary])
        }

        try await f.authorAgain()

        let failures = await f.ledger.records(for: Fixture.id).compactMap { record -> Evidence? in
            guard case .acceptanceTestPreflightFailed(let evidence) = record.event.kind else { return nil }
            return evidence
        }
        let failure = try #require(failures.last,
                                  "Preflight must inspect the recorded file, not just the ticket folder")
        #expect(failure.summary.contains(Fixture.primary))
        #expect(failure.summary.contains(CompilerDiagnostic.testRulePrefix))
        #expect(try await f.node().phase == .specified)
    }

    @Test
    func legacyRerunsCommitAllOwnFolderFilesAndDiscardUnlistedTestsAndProduction() async throws {
        let f = try await Fixture(recorded: false)
        defer { f.cleanUp() }
        await f.author.configure { task in
            try Files.write("func fixedLegacyTest() {}\n", at: Fixture.legacy, in: task.directory)
            try Files.write("func additionalLegacyTest() {}\n", at: Fixture.newOwn, in: task.directory)
            try Files.write("unlisted test edit", at: Fixture.unapproved, in: task.directory)
            try Files.write("placeholder", at: Fixture.production, in: task.directory)
            return AgentReport()
        }

        try await f.authorAgain()

        let committed = try #require(await f.workspace.committed)
        #expect(committed[Fixture.legacy] == "func fixedLegacyTest() {}\n")
        #expect(committed[Fixture.newOwn] == "func additionalLegacyTest() {}\n")
        #expect(committed[Fixture.other] == f.branch[Fixture.other])
        #expect(committed[Fixture.unapproved] == f.base[Fixture.unapproved])
        #expect(committed[Fixture.production] == f.base[Fixture.production])
        #expect(try await f.node().phase == .ready)
    }

    @Test(arguments: [ReviewStage.acceptanceTests, .change])
    func legacyReviewsShowOwnFolderFilesInFullAndChangedOtherTestsByPath(stage: ReviewStage) async throws {
        let f = try await Fixture(recorded: false)
        defer { f.cleanUp() }
        let request = try await f.review(stage, changed: [Fixture.legacy, Fixture.other])

        #expect(request.acceptanceTests[Fixture.legacy] == f.branch[Fixture.legacy])
        #expect(request.acceptanceTests[Fixture.other] == f.branch[Fixture.other])
        let prompt = CopilotReviewer.prompt(for: request)
        #expect(prompt.contains(try #require(f.branch[Fixture.legacy])))
        #expect(prompt.contains(Fixture.other))
        #expect(!prompt.contains(try #require(f.branch[Fixture.other])))
    }

    @Test
    func workspaceFixtureReallyRestoresSelectedPathsAndCommitsAddsEditsAndDeletes() async throws {
        let f = try await Fixture(recorded: false)
        defer { f.cleanUp() }
        let directory = try await f.workspace.createWorktree(for: Fixture.id, keeping: [Fixture.legacy])
        #expect(try Files.read(in: directory)[Fixture.legacy] == f.branch[Fixture.legacy])
        #expect(try Files.read(in: directory)[Fixture.other] == f.base[Fixture.other])
        try Files.write("new test", at: Fixture.newOwn, in: directory)
        try FileManager.default.removeItem(at: directory.appending(path: Fixture.legacy))
        try Files.write("discard me", at: Fixture.production, in: directory)
        try await f.workspace.discardChanges(keeping: [Fixture.ownFolder], in: directory)
        try #require(await f.workspace.commitAll(in: directory, message: "fixture probe", author: "probe") != nil)
        let committed = try #require(await f.workspace.committed)
        #expect(committed[Fixture.newOwn] == "new test")
        #expect(committed[Fixture.legacy] == nil)
        #expect(committed[Fixture.production] == f.base[Fixture.production])
        #expect(Set(try await f.workspace.changedFiles(in: directory)) == [Fixture.newOwn])
    }
}
