// Expected API: AgentOSCore.CheckFailureLocation(file: String?, suite: String?),
// CheckOutput(..., failureLocations: [CheckFailureLocation]), and
// TestFailureAttribution.owner(of:among:sources:) -> NodeID? (repository-relative
// source paths mapped to their contents). Landing uses the same attribution.
// SwiftPMCheckRunner and CommandCheckRunner populate CheckOutput.failureLocations
// with full repository-relative file paths and the reported suites.
// Swift Testing issues have a suite only when exactly one Swift Testing suite
// failed in the log, never from the last suite started; XCTest suites stay intact.
// Existing APIs: testsRecorded(files:suite:), runRound(waitForAgents:), ledger
// landingBatchOwnersRemoved / landingBatchSplit events, and tracker comments.
// Source-only criterion 6: real-repo-mode.md explains recorded files/suite, both
// ticket marker forms, and legacy folder/file attribution; reviewed against the diff.
import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

@Suite struct GH_161Tests {
    @Test
    func recordedSupportFileWinsOverRecordedSuiteMarkerAndLegacyName() async throws {
        let file = "Tests/GH_54Tests/GH_54Tests.swift"
        let nodes = try await Self.nodes([
            Definition("GH-5", files: [file], suite: "RecordedFiveTests"),
            Definition("GH-53", files: ["Tests/Elsewhere.swift"], suite: "FeatureTests"),
            Definition("GH-52"),
            Definition("GH-54"),
        ])
        let sources = [file: #"@Suite(.ticket("GH-52")) struct FeatureTests {}"#]
        #expect(Self.owner(file: file, suite: "FeatureTests", nodes: nodes, sources: sources) == "wn-GH-5")

        let support = "Tests/Features/Shared/GH_53TestsSupport.swift"
        let supportNodes = try await Self.nodes([
            Definition("GH-53", files: [support], suite: "RenamedFeatureTests"),
            Definition("GH-5"),
        ])
        #expect(Self.owner(file: support, suite: nil, nodes: supportNodes) == "wn-GH-53",
                "A recorded support file needs neither a matching suite nor a ticket-named folder")
        #expect(Self.owner(file: "Tests/Other/GH_53TestsSupport.swift", suite: nil, nodes: supportNodes) == nil,
                "The full recorded path, not just its basename, decides ownership")
    }

    @Test
    func recordedSuiteWinsOverMarkerAndLegacyFileWhenFailureFileIsNotRecorded() async throws {
        let nodes = try await Self.nodes([
            Definition("GH-5", files: ["Tests/Feature/Own.swift"], suite: "FeatureTests"),
            Definition("GH-53"),
            Definition("GH-54"),
        ])
        let file = "Tests/GH_54Tests/GH_54Tests.swift"
        let sources = [file: #"@Suite(.ticket("GH-53")) struct FeatureTests {}"#]
        #expect(Self.owner(file: file, suite: "FeatureTests", nodes: nodes, sources: sources) == "wn-GH-5")
        #expect(Self.owner(file: nil, suite: "FeatureTests", nodes: nodes) == "wn-GH-5",
                "A runner that reports only the recorded suite still identifies its owner")
        #expect(Self.owner(file: nil, suite: "LongerFeatureTests", nodes: nodes) == nil,
                "Recorded suites match exactly, not by substring")
    }

    @Test
    func ambiguousDecidingRecordRuleIsUnattributedWithoutTryingLowerRules() async throws {
        let file = "Tests/GH_54Tests/GH_54Tests.swift"
        let nodes = try await Self.nodes([
            Definition("GH-5", files: [file], suite: "OnlyFiveTests"),
            Definition("GH-53", files: [file], suite: "OnlyFiftyThreeTests"),
            Definition("GH-54"),
        ])
        #expect(Self.owner(file: file, suite: "OnlyFiveTests", nodes: nodes,
                           sources: [file: #"@Suite(.ticket("GH-54")) struct OnlyFiveTests {}"#]) == nil,
                "Ambiguous recorded files cannot be rescued by an unambiguous suite or marker")
        let suiteNodes = try await Self.nodes([
            Definition("GH-5", files: ["Tests/Five.swift"], suite: "SharedTests"),
            Definition("GH-53", files: ["Tests/FiftyThree.swift"], suite: "SharedTests"),
            Definition("GH-54"),
        ])
        #expect(Self.owner(file: file, suite: "SharedTests", nodes: suiteNodes,
                           sources: [file: #"@Suite(.ticket("GH-54")) struct SharedTests {}"#]) == nil,
                "An ambiguous recorded suite must not fall through to the marker")
    }

    @Test(arguments: MarkerForm.allCases)
    func suiteDeclarationMarkerUsesExactKnownTicketAndCanBeInADifferentFile(form: MarkerForm) async throws {
        let nodes = try await Self.nodes([
            Definition("GH-5"),
            Definition("GH-53", files: ["Tests/Old/Original.swift"], suite: "OldSuiteTests"),
        ])
        let declaration = "Tests/Features/Landing/Feature.swift"
        let sources = [declaration: form.source(suite: "FeatureTests", ticket: "GH-53")]
        #expect(Self.owner(file: "Tests/Helpers/Checks.swift", suite: "FeatureTests",
                           nodes: nodes, sources: sources) == "wn-GH-53")
        #expect(Self.owner(file: declaration, suite: "FeatureTests", nodes: Array(nodes.reversed()),
                           sources: sources) == "wn-GH-53",
                "GH-5 must never capture GH-53 and node iteration order must not choose an owner")
    }

    @Test(arguments: MarkerForm.allCases)
    func twoSuitesInOneFileAreAttributedToTheirOwnTicketMarkers(form: MarkerForm) async throws {
        let nodes = try await Self.nodes([Definition("GH-5"), Definition("GH-53")])
        let file = "Tests/Features/Feature.swift"
        let sources = [file: form.source(suite: "FeatureTests", ticket: "GH-53") + "\n"
                       + form.source(suite: "OtherTests", ticket: "GH-5")]
        #expect(Self.owner(file: file, suite: "FeatureTests", nodes: nodes,
                           sources: sources) == "wn-GH-53")
        #expect(Self.owner(file: file, suite: "OtherTests", nodes: nodes,
                           sources: sources) == "wn-GH-5")
    }

    @Test(arguments: InvalidMarker.allCases)
    func unrelatedMissingUnknownOrMultipleMarkersDoNotAttributeFailures(marker: InvalidMarker) async throws {
        let nodes = try await Self.nodes([Definition("GH-5"), Definition("GH-53")])
        let file = "Tests/Features/Feature.swift"
        #expect(Self.owner(file: file, suite: "FeatureTests", nodes: nodes,
                           sources: [file: marker.source]) == nil, "\(marker.rawValue)")
    }

    @Test
    func markerWinsOverLegacyNameForANodeWithoutARecord() async throws {
        let file = "Tests/GH_5Tests/GH_5Tests.swift"
        let nodes = try await Self.nodes([Definition("GH-5"), Definition("GH-53")])
        #expect(Self.owner(file: file, suite: "FeatureTests", nodes: nodes,
                           sources: [file: #"@Suite(.ticket("GH-53")) struct FeatureTests {}"#]) == "wn-GH-53")
    }

    @Test(arguments: MarkerForm.allCases)
    func unknownMarkerDoesNotFallBackToADifferentNodesLegacyName(form: MarkerForm) async throws {
        let file = "Tests/GH_5Tests/GH_5Tests.swift"
        let nodes = try await Self.nodes([Definition("GH-5"), Definition("GH-53")])
        #expect(Self.owner(file: file, suite: "FeatureTests", nodes: nodes,
                           sources: [file: form.source(suite: "FeatureTests", ticket: "UNKNOWN-1")]) == nil,
                "An unknown ticket marker must leave the failure unattributed")
    }

    @Test(arguments: [Ownership.recordedFile, .legacyFolder, .legacyFile])
    func aSuiteWithoutAMarkerStillUsesRecordedFilesOrLegacyNames(ownership: Ownership) async throws {
        let definition = ownership.definition("GH-53")
        let location = ownership.location(for: definition)
        let file = try #require(location.file)
        let nodes = try await Self.nodes([Definition("GH-5"), definition])
        #expect(Self.owner(file: file, suite: "UnrecordedFeatureTests", nodes: nodes,
                           sources: [file: "@Suite struct UnrecordedFeatureTests {}"]) == definition.id,
                "Missing markers neither override recorded files nor block the legacy fallback")
    }

    @Test
    func duplicateKnownTicketAndDuplicateLegacyTargetAreUnattributed() async throws {
        let nodes = try await Self.nodes([
            Definition("GH-53", id: "wn-First"), Definition("GH-53", id: "wn-Second"),
        ])
        let file = "Tests/Feature.swift"
        #expect(Self.owner(file: file, suite: "FeatureTests", nodes: nodes,
                           sources: [file: #"@Suite(.ticket("GH-53")) struct FeatureTests {}"#]) == nil)
        let legacy = try await Self.nodes([
            Definition("GH-5", id: "wn-A-B"), Definition("GH-53", id: "wn-A_B"),
        ])
        #expect(Self.owner(file: "Tests/A_BTests/Helpers.swift", suite: nil, nodes: legacy) == nil)
    }

    @Test(arguments: [Ownership.legacyFolder, .legacyFile])
    func legacyFallbackIsExactAndIsDisabledForNodesWithARecord(ownership: Ownership) async throws {
        let old = Definition("GH-53")
        let file = ownership.location(for: old).file
        let nodes = try await Self.nodes([Definition("GH-5"), old])
        #expect(Self.owner(file: file, suite: nil, nodes: nodes) == old.id)
        #expect(Self.owner(file: "Tests/PrefixGH_53Tests/Helpers.swift", suite: nil, nodes: nodes) == nil)
        #expect(Self.owner(file: "Tests/PrefixGH_53Tests.swift", suite: nil, nodes: nodes) == nil)
        let recorded = try await Self.nodes([Definition("GH-53", files: [], suite: "RenamedTests")])
        #expect(Self.owner(file: file, suite: nil, nodes: recorded) == nil,
                "A node with even an empty file record must not use its old inferred target")
    }

    @Test
    func fixtureCanLandExistingPassingSinglesAndBatches() async throws {
        for count in [1, 2] {
            let fixture = try await Fixture(count: count, ownership: .recordedFile, failure: .none)
            defer { fixture.cleanUp() }
            try await fixture.round()
            let state = await fixture.ledger.workingState()
            for id in fixture.ids {
                try #require(state.nodes[id]?.phase == .proven,
                             "Validate the fake workspace and runner against already-supported passing landings")
                let ticket = try #require(state.nodes[id]?.ticket)
                try #require(await fixture.tracker.comments(on: ticket).contains { $0.contains("Landed") })
            }
            try #require(await fixture.workspace.landings.contains(fixture.ids))
        }
    }

    @Test(arguments: Ownership.allCases)
    func singleLandingOwnFailureHasNoOtherTestsDiagnosis(ownership: Ownership) async throws {
        let fixture = try await Fixture(count: 1, ownership: ownership, failure: .own)
        defer { fixture.cleanUp() }
        try await fixture.round()
        let node = try #require(await fixture.ledger.workingState().nodes[fixture.ids[0]])
        #expect(node.phase != .proven)
        #expect(node.landingReworkPending)
        #expect(node.evidence.last?.failureClassification == .ownMistake)
        #expect(node.flags[.escalated] == nil)
        #expect(await fixture.checks.calls.filter { $0.only != nil || $0.nodes.isEmpty }.isEmpty,
                "An attributed own failure must not rerun another suite or diagnose against the baseline")
        let comments = await fixture.tracker.comments(on: node.ticket)
        #expect(comments.contains { $0.contains("own mistake") })
        #expect(!comments.contains { $0.contains("Requirements conflict:") })
    }

    @Test(arguments: Ownership.allCases)
    func singleLandingEscalatesOnlyProvenOtherOwnersAndCommentsOnTheirTickets(ownership: Ownership) async throws {
        let fixture = try await Fixture(count: 1, ownership: ownership, failure: .proven)
        defer { fixture.cleanUp() }
        try await fixture.round()
        let state = await fixture.ledger.workingState()
        let node = try #require(state.nodes[fixture.ids[0]])
        let reason = try #require(node.flags[.escalated])
        #expect(reason.contains("Requirements conflict:"))
        #expect(reason.contains("GH-5"))
        #expect(reason.contains("GH-53"))
        #expect(reason.contains("harness:retry"))
        #expect(node.landedCommit == nil)
        for other in fixture.proven {
            #expect(state.nodes[other.id]?.phase == .proven)
            #expect(await fixture.tracker.comments(on: other.ticket).contains {
                $0.contains("contradicts this ticket's acceptance criteria")
            })
        }
        #expect(await fixture.checks.calls.contains { $0.only != nil && $0.nodes.isEmpty },
                "Conflict attribution is exercised through the existing isolated baseline diagnosis")
    }

    @Test(arguments: [Failure.mixedOwnAndProven, .mixedOwnAndUnknown, .mixedUnknownAndProven, .unknown, .notProven, .ambiguous])
    func singleLandingNeverCallsMixedUnknownAmbiguousOrUnprovenFailuresARequirementsConflict(failure: Failure) async throws {
        let fixture = try await Fixture(count: 1, ownership: .recordedFile, failure: failure)
        defer { fixture.cleanUp() }
        try await fixture.round()
        let node = try #require(await fixture.ledger.workingState().nodes[fixture.ids[0]])
        #expect(node.landedCommit == nil)
        #expect(node.evidence.last?.failureClassification == .ownMistake)
        #expect(node.landingReworkPending)
        #expect(node.flags[.escalated] == nil)
        #expect(await fixture.tracker.comments(on: node.ticket).contains { $0.contains("own mistake") })
        for other in fixture.proven {
            #expect(await fixture.tracker.comments(on: other.ticket).allSatisfy {
                !$0.contains("contradicts this ticket's acceptance criteria")
            })
        }
    }

    @Test(arguments: Ownership.allCases)
    func batchRemovesAllAttributedMembersAndRechecksTheRestWithoutThem(ownership: Ownership) async throws {
        let fixture = try await Fixture(count: 4, ownership: ownership, failure: .own)
        defer { fixture.cleanUp() }
        try await fixture.round()
        let original = try await fixture.originalBatch()
        let removed = [fixture.ids[0], fixture.ids[2]]
        let remaining = [fixture.ids[1], fixture.ids[3]]
        let records = await fixture.ledger.allRecords()
        #expect(records.contains {
            if case .landingBatchOwnersRemoved(let batch, let actualRemoved, let actualRemaining) = $0.event.kind {
                return batch == original.name && actualRemoved == removed && actualRemaining == remaining
            }
            return false
        })
        #expect(!records.contains {
            if case .landingBatchSplit(let batch, _, _) = $0.event.kind { return batch == original.name }
            return false
        })
        let calls = await fixture.checks.calls
        #expect(calls.contains { $0.only == nil && $0.nodes == remaining },
                "Healthy members are checked as a fresh candidate with neither failing member applied")
        let state = await fixture.ledger.workingState()
        for id in remaining {
            #expect(state.nodes[id]?.phase == .proven)
            let ticket = try #require(state.nodes[id]?.ticket)
            #expect(await fixture.tracker.comments(on: ticket).contains { $0.contains("Landed") })
        }
        for id in removed { #expect(state.nodes[id]?.landedCommit == nil) }
    }

    @Test(arguments: [Failure.mixedOwnAndProven, .mixedOwnAndUnknown, .mixedUnknownAndProven, .unknown, .proven, .notProven, .ambiguous])
    func batchSplitsInHalfWhenAnyFailureIsUnattributedOrOwnedOutsideTheBatch(failure: Failure) async throws {
        let fixture = try await Fixture(count: 4, ownership: .recordedFile, failure: failure)
        defer { fixture.cleanUp() }
        try await fixture.round()
        let original = try await fixture.originalBatch()
        let records = await fixture.ledger.allRecords()
        #expect(records.contains {
            if case .landingBatchSplit(let batch, let first, let second) = $0.event.kind {
                return batch == original.name && first == Array(fixture.ids.prefix(2))
                    && second == Array(fixture.ids.suffix(2))
            }
            return false
        })
        #expect(!records.contains {
            if case .landingBatchOwnersRemoved(let batch, _, _) = $0.event.kind { return batch == original.name }
            return false
        })
        #expect(await fixture.checks.calls.contains {
            $0.only == nil && $0.nodes == Array(fixture.ids.prefix(2))
        })
    }

    @Test(arguments: FailureOutput.allCases)
    func commandCheckRunnerReportsFullFailureFileAndSuite(format: FailureOutput) async throws {
        let directory = try Self.parsingDirectory()
        defer { Self.removeParsingDirectory(directory) }
        let file = "Tests/Features/Unrelated/GH_53TestsSupport.swift"
        let log = format.log(file: directory.appending(path: file).path)
        try log.write(to: directory.appending(path: "failure.log"), atomically: true, encoding: .utf8)
        let runner = CommandCheckRunner(config: RepoConfig(test: .init(command: "cat failure.log; exit 1")))
        let output = try await withHangGuard("GH-161 real command check") {
            await runner.runChecks(in: directory, only: nil)
        }
        try #require(!output.passed && output.log.contains(log),
                     "The fixture must actually emit the failing runner output")
        try #require(output.checks.contains { $0.name == "test" && !$0.passed },
                     "Validate the command fixture against existing check execution")
        #expect(output.failureLocations.contains { $0.file == file && $0.suite == "FeatureTests" },
                "Keep the unrelated folder and support filename, and identify the suite from the output")
    }

    @Test
    func commandCheckRunnerDoesNotGuessBetweenParallelSwiftTestingSuitesOrChangeXCTestSuite() async throws {
        let directory = try Self.parsingDirectory()
        defer { Self.removeParsingDirectory(directory) }
        let first = "Tests/Features/Landing/GH_53TestsSupport.swift"
        let second = "Tests/Features/Checking/Assertions.swift"
        let xctest = "Tests/Features/Legacy/LegacyAssertions.swift"
        let log = """
            Suite FeatureTests started.
            Suite OtherFeatureTests started.
            Test preservedBehavior() started.
            Test otherBehavior() started.
            Test preservedBehavior() recorded an issue at \(directory.appending(path: first).path):12:3: Expectation failed: false
            Test Suite 'LegacyTests' started.
            Test Case '-[ParserFixture.LegacyTests testBehavior]' started.
            \(directory.appending(path: xctest).path):20: error: -[ParserFixture.LegacyTests testBehavior] : XCTAssertTrue failed
            Test otherBehavior() recorded an issue at \(directory.appending(path: second).path):15:3: Expectation failed: false
            Test Case '-[ParserFixture.LegacyTests testBehavior]' failed (0.001 seconds).
            Test preservedBehavior() failed after 0.001 seconds with 1 issue.
            Suite FeatureTests failed after 0.001 seconds with 1 issue.
            Test otherBehavior() failed after 0.001 seconds with 1 issue.
            Suite OtherFeatureTests failed after 0.001 seconds with 1 issue.
            Suite UnrelatedTests started.
            """
        try log.write(to: directory.appending(path: "failure.log"), atomically: true, encoding: .utf8)
        let runner = CommandCheckRunner(config: RepoConfig(test: .init(command: "cat failure.log; exit 1")))
        let output = try await withHangGuard("GH-161 mixed command check output") {
            await runner.runChecks(in: directory, only: nil)
        }
        try #require(!output.passed && output.log.contains(log),
                     "The command fixture must emit the complete mixed failure log")
        try #require(output.checks.contains { $0.name == "test" && !$0.passed })
        for file in [first, second] {
            let locations = output.failureLocations.filter { $0.file == file }
            #expect(!locations.isEmpty, "Preserve each Swift Testing issue's repository-relative file")
            #expect(locations.allSatisfy { $0.suite == nil },
                    "Two failed Swift Testing suites are ambiguous; neither failure nor start order decides ownership")
        }
        let legacyLocations = output.failureLocations.filter { $0.file == xctest }
        #expect(!legacyLocations.isEmpty, "Preserve the XCTest diagnostic's repository-relative file")
        #expect(legacyLocations.allSatisfy { $0.suite == "LegacyTests" },
                "Mixed Swift Testing output must not erase or replace the explicit XCTest suite")
    }

    @Test
    func swiftPMCheckRunnerReportsTheSupportFilesRepositoryPathAndFailingSuite() async throws {
        let directory = try Self.parsingDirectory()
        defer { Self.removeParsingDirectory(directory) }
        let files = [
            "Package.swift": """
                // swift-tools-version: 6.0
                import PackageDescription
                let package = Package(name: "ParserFixture", targets: [
                    .testTarget(name: "ParserFixture")
                ])
                """,
            "Tests/ParserFixture/Feature.swift": """
                import Testing
                @Suite struct FeatureTests {
                    @Test func preservedBehavior() { recordFailure() }
                }
                """,
            "Tests/ParserFixture/Unrelated/GH_53TestsSupport.swift": """
                import Testing
                func recordFailure() { Issue.record("GH-161 parser fixture failure") }
                """,
        ]
        for (file, contents) in files {
            let url = directory.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let output = try await withHangGuard("GH-161 real SwiftPM failure", timeout: .seconds(300)) {
            await SwiftPMCheckRunner().runChecks(in: directory, only: nil)
        }
        try #require(!output.passed && output.log.contains("GH-161 parser fixture failure"),
                     "Validate that the fixture compiled and reached its intentional test failure")
        #expect(output.failureLocations.contains {
            $0.file == "Tests/ParserFixture/Unrelated/GH_53TestsSupport.swift" && $0.suite == "FeatureTests"
        }, "The real SwiftPM runner must preserve the repository path and identify the suite")
    }

    private static func parsingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "GH-161-parser-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func removeParsingDirectory(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Could not remove GH-161 parser fixture: \(error)") }
    }

    enum FailureOutput: String, CaseIterable, Sendable {
        case swiftTesting, xctest

        func log(file: String) -> String {
            switch self {
            case .swiftTesting:
                """
                Suite FeatureTests started.
                Test preservedBehavior() started.
                Test preservedBehavior() recorded an issue at \(file):12:3: Expectation failed: false
                Test preservedBehavior() failed after 0.001 seconds with 1 issue.
                Suite FeatureTests failed after 0.001 seconds with 1 issue.
                """
            case .xctest:
                """
                Test Suite 'FeatureTests' started.
                Test Case '-[ParserFixture.FeatureTests testBehavior]' started.
                \(file):12: error: -[ParserFixture.FeatureTests testBehavior] : XCTAssertTrue failed
                Test Case '-[ParserFixture.FeatureTests testBehavior]' failed (0.001 seconds).
                """
            }
        }
    }

    private static func owner(file: String?, suite: String?, nodes: [NodeState],
                              sources: [String: String] = [:]) -> NodeID? {
        TestFailureAttribution.owner(of: CheckFailureLocation(file: file, suite: suite),
                                     among: nodes, sources: sources)
    }

    private static func nodes(_ definitions: [Definition]) async throws -> [NodeState] {
        let ledger = try Ledger()
        for definition in definitions { try await ledger.append(definition.creationEvents(parent: nil)) }
        let state = await ledger.workingState()
        return try definitions.map { try #require(state.nodes[$0.id]) }
    }

    enum MarkerForm: String, CaseIterable, Sendable {
        case trait, comment, xctestComment
        func source(suite: String, ticket: String) -> String {
            switch self {
            case .trait:
                """
                @Suite(
                    "Landing behavior",
                    .ticket("\(ticket)")
                )
                struct \(suite) {}
                """
            case .comment: "// Ticket: \(ticket)\n@Suite struct \(suite) {}"
            case .xctestComment: "// Ticket: \(ticket)\nfinal class \(suite): XCTestCase {}"
            }
        }
    }

    enum InvalidMarker: String, CaseIterable, Sendable {
        case absent, unknownTrait, unknownComment, shortKeyTrait, shortKeyComment, caseMismatch
        case unrelatedComment, stringLiteral, otherSuiteTrait, otherSuiteComment
        case twoTraits, duplicateTrait, traitAndComment, knownAndUnknownTrait
        case separatedComment, stringInAttribute, commentedTrait
        var source: String {
            switch self {
            case .absent: "@Suite struct FeatureTests {}"
            case .unknownTrait: #"@Suite(.ticket("GH-999")) struct FeatureTests {}"#
            case .unknownComment: "// Ticket: GH-999\n@Suite struct FeatureTests {}"
            case .shortKeyTrait: #"@Suite(.ticket("GH-530")) struct FeatureTests {}"#
            case .shortKeyComment: "// Ticket: GH-530\n@Suite struct FeatureTests {}"
            case .caseMismatch: #"@Suite(.ticket("gh-53")) struct FeatureTests {}"#
            case .unrelatedComment: "// Fixes GH-53\n@Suite struct FeatureTests {}"
            case .stringLiteral: #"let note = "GH-53"; @Suite struct FeatureTests {}"#
            case .otherSuiteTrait:
                """
                @Suite(.ticket("GH-53")) struct OtherTests {}
                @Suite struct FeatureTests {}
                """
            case .otherSuiteComment:
                """
                // Ticket: GH-53
                @Suite struct OtherTests {}
                @Suite struct FeatureTests {}
                """
            case .twoTraits: #"@Suite(.ticket("GH-5"), .ticket("GH-53")) struct FeatureTests {}"#
            case .duplicateTrait: #"@Suite(.ticket("GH-53"), .ticket("GH-53")) struct FeatureTests {}"#
            case .traitAndComment: "// Ticket: GH-53\n@Suite(.ticket(\"GH-53\")) struct FeatureTests {}"
            case .knownAndUnknownTrait:
                #"@Suite(.ticket("GH-53"), .ticket("GH-999")) struct FeatureTests {}"#
            case .separatedComment: "// Ticket: GH-53\n\n@Suite struct FeatureTests {}"
            case .stringInAttribute: #"@Suite("mentions .ticket(\"GH-53\")") struct FeatureTests {}"#
            case .commentedTrait: #"@Suite(/* .ticket("GH-53") */) struct FeatureTests {}"#
            }
        }
    }
}
