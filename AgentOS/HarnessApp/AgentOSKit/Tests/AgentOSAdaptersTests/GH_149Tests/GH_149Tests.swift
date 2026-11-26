// Expected API: AgentOSCore.EventKind.testsRecorded(files: [String], suite: String) records
// repository-relative own-test paths. Hashing.digest(ofRecordedFiles: [String], in: URL) fingerprints
// those paths, distinguishing missing/unreadable files from readable empty files.
// Existing Reconciler.testsDigest, preCheck, rebaseOntoMain,
// resetForRework and retryRequirementCatchUp must respect that record and renew only intact locks.
// All five GH-149 criteria are behavioral; there are no source-only criteria in this work item.
import Foundation
import Testing
@testable import AgentOSCore

@Suite struct GH_149Tests {
    @Test
    func testAuthorStoresTheRecordedFingerprintInTestsFixed() async throws {
        try await Self.withFixture { f in
            await f.workspace.allowAcceptanceCommit()
            let authoring = f.makeReconciler(ledger: f.ledger, testAuthor: AcceptanceAuthor())
            _ = try await authoring.authorTests(try await f.node())
            let authored = try await f.node()
            let fixed = try #require(authored.testsDigest)
            #expect(authored.phase == .ready)
            #expect(authored.flags[.escalated] == nil)
            #expect(await authoring.testsDigest(authored, in: f.directory) == fixed)

            try f.write(Self.ownFolder + "/NotRecordedAtCommit.swift", "an unrecorded addition")
            #expect(await authoring.testsDigest(authored, in: f.directory) == fixed,
                    "The actual testsFixed event must use the recorded-file fingerprint, not the folder digest.")
            try f.write(Self.ownFile, "changed recorded acceptance test")
            #expect(await authoring.testsDigest(authored, in: f.directory) != fixed)
        }
    }

    @Test
    func fixedDigestCoversRecordedFilesButNotUnrecordedFilesInTheTestArea() async throws {
        try await Self.withFixture { f in
            let unrecorded = [Self.ownFolder + "/ExistingUnrecorded.swift", Self.foreignFile]
            for path in unrecorded { try f.write(path, "existing unrecorded test") }
            try await f.lock()
            let fixed = try #require(await f.node().testsDigest)

            for path in unrecorded {
                try f.write(path, "changed unrecorded test")
                #expect(try await f.digest() == fixed, "An unrecorded path must not enter the own-test fingerprint.")
                try f.remove(path)
                #expect(try await f.digest() == fixed)
            }
            try f.write(Self.ownFile, "changed recorded test")
            #expect(try await f.digest() != fixed)
        }
    }

    @Test(arguments: [Mutation.delete, .unreadable])
    func missingOrUnreadableRecordedEmptyFileDoesNotFingerprintAsExistingEmpty(_ mutation: Mutation) async throws {
        try await Self.withFixture { f in
            try await f.lock()
            let fixed = try #require(await f.node().testsDigest)
            try f.mutate(Self.emptyFile, using: mutation)
            #expect(try await f.digest() != fixed,
                    "The recorded path's unreadable/missing state must differ from readable empty contents.")
        }
    }

    @Test(arguments: [Mutation.change, .delete, .unreadable], [false, true])
    func precheckRejectsChangedDeletedOrUnreadableRecordedFiles(_ mutation: Mutation, empty: Bool) async throws {
        try await Self.withFixture { f in
            try await f.lock()
            let path = empty ? Self.emptyFile : Self.ownFile
            try f.mutate(path, using: mutation)
            await f.workspace.setChangedFiles(Self.recordedFiles)

            let evidence = try await f.precheck()
            #expect(!evidence.passed)
            #expect(evidence.summary == Self.ownViolation)
            #expect(await f.checks.calls == 0, "A violated lock must fail before invoking the check runner.")
        }
    }

    @Test
    func addingAnUnrecordedFileToTheOwnFolderFailsWithoutChangingTheRecordedDigest() async throws {
        try await Self.withFixture { f in
            try await f.lock()
            let fixed = try #require(await f.node().testsDigest)
            let addition = Self.ownFolder + "/InjectedHelper.swift"
            try f.write(addition, "new unrecorded test")
            await f.workspace.setChangedFiles(Self.recordedFiles + [addition])

            #expect(try await f.digest() == fixed)
            let evidence = try await f.precheck()
            #expect(!evidence.passed)
            #expect(evidence.summary == Self.ownViolation)
            #expect(await f.checks.calls == 0)
        }
    }

    @Test(arguments: Mutation.fileChanges)
    func precheckRejectsAddedChangedOrDeletedUnrecordedOtherTests(_ mutation: Mutation) async throws {
        try await Self.withFixture { f in
            if mutation != .add { try f.write(Self.foreignFile, "another node's existing tests") }
            try await f.lock()
            let fixed = try #require(await f.node().testsDigest)
            try f.mutate(Self.foreignFile, using: mutation)
            await f.workspace.setChangedFiles(Self.recordedFiles + [Self.foreignFile])

            #expect(try await f.digest() == fixed)
            let evidence = try await f.precheck()
            #expect(!evidence.passed)
            #expect(evidence.summary == "Changed other nodes' tests (not allowed): \(Self.foreignFile)")
            #expect(await f.checks.calls == 0)
        }
    }

    @Test
    func fingerprintedOtherTestUpdatesAreAllowedButTheirLaterChangesAreNot() async throws {
        try await Self.withFixture { f in
            try f.write(Self.updatedFile, "the test author's deliberately updated expectations")
            try await f.lock(updated: [Self.updatedFile])
            await f.workspace.setChangedFiles(Self.recordedFiles + [Self.updatedFile])
            #expect(try await f.precheck().passed)
            #expect(await f.checks.calls == 1)

            try f.write(Self.updatedFile, "the implementer changed somebody else's expectations")
            let evidence = try await f.precheck()
            #expect(!evidence.passed)
            #expect(evidence.summary == Self.updatedViolation)
            #expect(await f.checks.calls == 1)
        }
    }

    @Test
    func anUnchangedLegacyFolderLockStillPassesAfterLedgerReload() async throws {
        try await Self.withFixture { f in
            try await f.lock(recorded: false, legacyDigest: Self.legacyDigest)
            let folder = f.directory.appending(path: Self.ownFolder)
            let original = try #require(await f.node().testsDigest)
            #expect(original == Self.legacyDigest)
            #expect(original == Hashing.digest(of: folder))

            let records = try Hashing.decoder().decode(
                [RecordedEvent].self, from: Hashing.canonicalJSON(await f.ledger.allRecords()))
            let store = InMemoryLedgerStore()
            store.append(records)
            let reloaded = try Ledger(store: store)
            #expect(await reloaded.verifyChain().isIntact)
            let reconciler = f.makeReconciler(ledger: reloaded)
            let node = try #require(await reloaded.workingState().nodes[Self.nodeID])
            #expect(node.testsDigest == original)
            #expect(await reconciler.testsDigest(node, in: f.directory) == original)
            _ = try await reconciler.preCheck(node)
            let checked = try #require(await reloaded.workingState().nodes[Self.nodeID]?.evidence.last)
            #expect(checked.passed)
            #expect(await f.checks.calls == 1)
        }
    }

    @Test(arguments: Mutation.fileChanges)
    func aNodeWithoutARecordStillLocksEveryFileInItsFolder(_ mutation: Mutation) async throws {
        try await Self.withFixture { f in
            let path = Self.ownFolder + "/LegacyHelper.swift"
            if mutation != .add { try f.write(path, "legacy acceptance helper") }
            try await f.lock(recorded: false)
            try f.mutate(path, using: mutation)
            await f.workspace.setChangedFiles(Self.recordedFiles + [path])

            let evidence = try await f.precheck()
            #expect(!evidence.passed)
            #expect(evidence.summary == Self.ownViolation)
            #expect(await f.checks.calls == 0)
        }
    }

    @Test(arguments: Move.allCases)
    func intactRecordedAndUpdatedTestLocksSurviveHarnessMoves(_ move: Move) async throws {
        try await Self.withFixture { f in
            try f.write(Self.updatedFile, "original other-test update")
            try await f.lock(updated: [Self.updatedFile])
            await f.workspace.setChangedFiles(Self.recordedFiles + [Self.updatedFile])
            try await f.expectIntact()
            await f.workspace.setMoveEdits([
                FileEdit(path: Self.ownFile, contents: "main's legitimate recorded-test update"),
                FileEdit(path: Self.updatedFile, contents: "main's legitimate other-test update"),
            ])

            try await f.move(move)

            #expect(await f.workspace.moves == 1)
            #expect(try await f.precheck().passed)
            let renewed = try await f.node()
            #expect(renewed.updatedOtherTests == [Self.updatedFile])
            #expect(renewed.updatedOtherTestsDigest == Hashing.digest(ofFiles: [Self.updatedFile], in: f.directory))

            // Renewal must not replace the record with a folder lock.
            let fixed = try #require(renewed.testsDigest)
            try f.write(Self.ownFolder + "/UnrecordedFromMain.swift", "new baseline test")
            #expect(try await f.digest() == fixed)
            #expect(try await f.precheck().passed)
            try f.write(Self.emptyFile, "tampered after renewal")
            #expect(try await f.precheck().summary == Self.ownViolation)
        }
    }

    @Test(arguments: Move.allCases, Damage.allCases)
    func harnessMovesNeverLegitimizePreviouslyTamperedLocks(_ move: Move, damage: Damage) async throws {
        try await Self.withFixture { f in
            try f.write(Self.updatedFile, "original other-test update")
            try await f.lock(updated: [Self.updatedFile])
            await f.workspace.setChangedFiles(Self.recordedFiles + [Self.updatedFile])
            try await f.expectIntact()
            let path = damage == .recorded ? Self.ownFile : Self.updatedFile
            try f.write(path, "committed tampering before the harness move")
            #expect(try await f.violation() != nil, "The fixture must start the move with a broken lock.")
            await f.workspace.setMoveEdits([
                FileEdit(path: Self.ownFile, contents: "main's later recorded-test version"),
                FileEdit(path: Self.updatedFile, contents: "main's later other-test version"),
            ])

            try await f.move(move)

            #expect(await f.workspace.moves == 1)
            let evidence = try await f.precheck()
            #expect(!evidence.passed, "A harness move must not launder a lock that was already broken.")
            #expect(evidence.summary.contains("(not allowed)"))
            #expect(await f.checks.calls == 0)
        }
    }
}
