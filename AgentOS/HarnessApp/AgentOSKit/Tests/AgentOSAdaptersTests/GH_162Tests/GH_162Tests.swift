// API: existing EventKind.testsRecorded(files:suite:), BrokenTestReport(testName:reason:),
// Reconciler.routeBrokenTest(_:from:run:author:directory:keptImplementation:) and
// Reconciler.isWaitingOnOtherTest(_:) must use the same ownership attribution.
// Routing is observed through ledger outcomes, phases and tracker comments. No new API
// or placeholders are required. All five criteria are behavioral; none are source-only.
import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSCore

@Suite struct GH_162Tests {
    @Test(arguments: ["", ":41"])
    func aReportInARecordedSupportFileIsSentToItsOwnTestAuthor(locationSuffix: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        try await fixture.expectRouting(Self.ownFile + locationSuffix, own: true)
    }

    @Test func theRecordedSuiteOverridesTheOldTicketNameAndAnotherTicketsMarker() async throws {
        let fixture = try await Fixture(files: [
            Self.markerFile: "@Suite(.ticket(\"GH-53\"))\nstruct \(Self.ownSuite) {}\n",
        ])
        defer { fixture.remove() }

        try await fixture.expectRouting("\(Self.ownSuite).checksContract", own: true)
    }

    @Test(arguments: MarkerForm.allCases)
    func aSuiteMarkedForThisTicketIsSentToItsOwnTestAuthor(form: MarkerForm) async throws {
        let fixture = try await Fixture(files: [
            Self.markerFile: form.source(suite: "MovedContractTests", ticket: "GH-5"),
        ])
        defer { fixture.remove() }

        try await fixture.expectRouting("MovedContractTests.checksContract", own: true)
    }

    @Test func aTicketTraitBelongsToItsSuiteNotEverySuiteInTheFile() async throws {
        let fixture = try await Fixture(files: [
            Self.markerFile: """
                @Suite(.ticket("GH-53"))
                struct OtherContractTests {}
                @Suite(
                    .serialized,
                    .ticket("GH-5")
                )
                struct MovedContractTests {}
                """,
        ])
        defer { fixture.remove() }

        try await fixture.expectRouting("MovedContractTests.checksContract", own: true)
    }

    @Test func aFileRecordedByOtherWorkIsNotOwnedByItsOldFolderName() async throws {
        let file = Self.oldFolder + "/ForeignSupport.swift"
        let fixture = try await Fixture(files: [file: "// Shared test support\n"])
        defer { fixture.remove() }
        try await fixture.recordOther(files: [file], suite: "ForeignContract")

        try await fixture.expectRouting(file + ":12", own: false)
    }

    @Test(arguments: [false, true])
    func anotherNodesRecordedSuiteOverridesPermissiveNameFallback(reportingNodeHasRecord: Bool) async throws {
        let fixture = try await Fixture(recorded: reportingNodeHasRecord)
        defer { fixture.remove() }
        try await fixture.recordOther(files: [], suite: "ForeignContract")

        try await fixture.expectRouting("ForeignContract.checksContract", own: false)
    }

    @Test(arguments: MarkerForm.allCases)
    func anotherTicketsMarkerIsOtherWorkAndTicketKeysMatchExactly(form: MarkerForm) async throws {
        let fixture = try await Fixture(files: [
            Self.markerFile: form.source(suite: "ForeignContract", ticket: "GH-53"),
        ])
        defer { fixture.remove() }

        // GH-5 must not own the GH-53 marker, even though its key is a prefix.
        try await fixture.expectRouting("ForeignContract.checksContract", own: false)
    }

    @Test(arguments: InvalidMarker.allCases)
    func anUnattributedReportFallsBackAgainstTheRecordedSuiteNotTheOldSuite(marker: InvalidMarker) async throws {
        let fixture = try await Fixture(files: [Self.markerFile: marker.source])
        defer { fixture.remove() }

        try await fixture.expectRouting("GH_5Tests.checksContract", own: false)
    }

    @Test(arguments: [
        ("checksContract", true),
        ("UnknownTests.checksContract", false),
        ("UnknownContract.checksContract", true),
    ])
    func anUnattributedNameKeepsTodaysPermissiveFallbackForRecordedNodes(
        report: String, own: Bool
    ) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        try await fixture.expectRouting(report, own: own)
    }

    @Test(arguments: [
        ("GH_5Tests.checksContract", true),
        ("GH_53Tests.checksContract", false),
        ("checksContract", true),
        ("UnknownContract.checksContract", true),
        ("Tests/AgentOSAdaptersTests/GH_5Tests/Contract.swift:8", true),
        ("Tests/AgentOSAdaptersTests/GH_53Tests/Contract.swift:8", false),
    ])
    func nodesWithoutARecordKeepTheirExistingNameAndFolderRouting(
        report: String, own: Bool
    ) async throws {
        let fixture = try await Fixture(recorded: false, files: [
            Self.oldFolder + "/Contract.swift": "struct GH_5Tests {}\n",
            "Tests/AgentOSAdaptersTests/GH_53Tests/Contract.swift": "struct GH_53Tests {}\n",
        ])
        defer { fixture.remove() }

        try await fixture.expectRouting(report, own: own)
    }

    @Test(arguments: [false, true])
    func aTestOutsideUpdatableAreasIsOtherWorkEvenWhenItsSuiteOrFileIsRecorded(recorded: Bool) async throws {
        let file = "Integration/Contract.swift"
        let fixture = try await Fixture(
            recorded: recorded, ownFiles: [file], ownSuite: "GH_5Tests",
            files: [file: "struct GH_5Tests {}\n"])
        defer { fixture.remove() }

        try await fixture.route("GH_5Tests.checksContract")
        try await fixture.expectWaiting(own: false)
        #expect(await fixture.outcomes() == [.otherTestWaitingForPerson])
        let comment = try #require(await fixture.tracker.comments.last)
        #expect(comment.contains(file))
        #expect(comment.contains("outside"))
        #expect(!comment.contains("sent back to the test author"))
    }

    @Test(arguments: [Self.ownFile + ":41", Self.ownSuite + ".checksContract"])
    func anOlderReportWithoutARoutingOutcomeUsesTheNodesRecordedFilesAndSuite(report: String) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }

        try await fixture.oldReport(report)
        #expect(await fixture.outcomes().isEmpty)
        #expect(await fixture.reconciler.isWaitingOnOtherTest(try await fixture.node()) == false)
        #expect(await fixture.reconciler.isWaitingOnOwnTest(try await fixture.node()))
    }

    @Test(arguments: MarkerForm.allCases, [true, false])
    func anOlderReportWithoutARoutingOutcomeUsesTheSameTicketMarkers(form: MarkerForm, own: Bool) async throws {
        let suite = own ? "MovedContractTests" : "ForeignContract"
        let fixture = try await Fixture(files: [
            Self.markerFile: form.source(suite: suite, ticket: own ? "GH-5" : "GH-53"),
        ])
        defer { fixture.remove() }

        try await fixture.oldReport("\(suite).checksContract")
        #expect(await fixture.outcomes().isEmpty)
        #expect(await fixture.reconciler.isWaitingOnOtherTest(try await fixture.node()) == !own)
        #expect(await fixture.reconciler.isWaitingOnOwnTest(try await fixture.node()) == own)
    }

    @Test(arguments: ["ForeignContract.checksContract", "Tests/AgentOSAdaptersTests/GH_5Tests/ForeignSupport.swift:12"])
    func anOlderReportWithoutARoutingOutcomeUsesAnotherNodesRecord(report: String) async throws {
        let file = Self.oldFolder + "/ForeignSupport.swift"
        let fixture = try await Fixture(files: [file: "// Shared test support\n"])
        defer { fixture.remove() }
        try await fixture.recordOther(files: [file], suite: "ForeignContract")

        try await fixture.oldReport(report)
        #expect(await fixture.outcomes().isEmpty)
        #expect(await fixture.reconciler.isWaitingOnOtherTest(try await fixture.node()))
    }

    @Test(arguments: [
        ("GH_5Tests.checksContract", true, false),
        ("GH_5Tests.checksContract", false, true),
        ("GH_53Tests.checksContract", false, false),
        ("checksContract", true, true),
    ])
    func olderUnattributedReportsUseRecordedSuiteFallbackOrLegacyNames(
        report: String, own: Bool, recorded: Bool
    ) async throws {
        let fixture = try await Fixture(recorded: recorded)
        defer { fixture.remove() }

        try await fixture.oldReport(report)
        #expect(await fixture.outcomes().isEmpty)
        #expect(await fixture.reconciler.isWaitingOnOtherTest(try await fixture.node()) == !own)
    }

    @Test(arguments: [false, true])
    func anOlderUnroutedReportStillRecognizesATestOutsideUpdatableAreas(recorded: Bool) async throws {
        let file = "Integration/Contract.swift"
        let fixture = try await Fixture(
            recorded: recorded, ownFiles: [file], ownSuite: "GH_5Tests",
            files: [file: "struct GH_5Tests {}\n"])
        defer { fixture.remove() }

        try await fixture.oldReport("GH_5Tests.checksContract")
        #expect(await fixture.outcomes().isEmpty)
        #expect(await fixture.reconciler.isWaitingOnOtherTest(try await fixture.node()))
    }

    @Test(arguments: [true, false])
    func anExistingRoutingOutcomeIsKeptInsteadOfReattributingAnOldReport(recordedAsOther: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let name = recordedAsOther ? "\(Self.ownSuite).checksContract" : "GH_53Tests.checksContract"

        try await fixture.oldReport(name, outcome: recordedAsOther ? .otherTestWaitingForPerson : .waitingForPerson)
        #expect(await fixture.reconciler.isWaitingOnOtherTest(try await fixture.node()) == recordedAsOther)
        #expect(await fixture.reconciler.isWaitingOnOwnTest(try await fixture.node()) == !recordedAsOther)
    }
}

extension GH_162Tests {
    enum MarkerForm: CaseIterable, Sendable {
        case trait, multilineTrait, comment, xctestComment

        func source(suite: String, ticket: String) -> String {
            switch self {
            case .trait:
                return "@Suite(.ticket(\"\(ticket)\"))\nstruct \(suite) {}\n"
            case .multilineTrait:
                return "@Suite(\n    .serialized,\n    .ticket(\"\(ticket)\")\n)\nstruct \(suite) {}\n"
            case .comment:
                return "// Ticket: \(ticket)\nstruct \(suite) {}\n"
            case .xctestComment:
                return "// Ticket: \(ticket)\nfinal class \(suite): XCTestCase {}\n"
            }
        }
    }

    enum InvalidMarker: CaseIterable, Sendable {
        case absent, unknownKey, duplicateTraits, conflictingTraits, conflictingForms
        case incidentalMentions, separatedComment, anotherSuite, anotherSuitesComment

        var source: String {
            switch self {
            case .absent:
                return "struct GH_5Tests {}\n"
            case .unknownKey:
                return "@Suite(.ticket(\"GH-500\"))\nstruct GH_5Tests {}\n"
            case .duplicateTraits:
                return "@Suite(.ticket(\"GH-5\"), .ticket(\"GH-5\"))\nstruct GH_5Tests {}\n"
            case .conflictingTraits:
                return "@Suite(.ticket(\"GH-5\"), .ticket(\"GH-53\"))\nstruct GH_5Tests {}\n"
            case .conflictingForms:
                return "@Suite(.ticket(\"GH-5\"))\n// Ticket: GH-53\nstruct GH_5Tests {}\n"
            case .incidentalMentions:
                return """
                    // GH-5 is mentioned here, but this is not a ticket marker.
                    let note = "GH-5"
                    let fixture = "// Ticket: GH-5"
                    // An example: .ticket("GH-5")
                    struct GH_5Tests {}
                    """
            case .separatedComment:
                return "// Ticket: GH-5\n\nstruct GH_5Tests {}\n"
            case .anotherSuite:
                return "@Suite(.ticket(\"GH-5\"))\nstruct UnrelatedTests {}\nstruct GH_5Tests {}\n"
            case .anotherSuitesComment:
                return "// Ticket: GH-5\nstruct UnrelatedTests {}\nstruct GH_5Tests {}\n"
            }
        }
    }
}
