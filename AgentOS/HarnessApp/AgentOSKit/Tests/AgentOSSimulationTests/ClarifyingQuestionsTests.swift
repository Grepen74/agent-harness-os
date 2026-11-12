import Foundation
import Testing
import AgentOSAdapters
@testable import AgentOSCore
@testable import AgentOSSimulation

@Suite("Clarifying questions")
struct ClarifyingQuestionsTests {
    @Test func decomposerQuestionsStopTheNodeUntilAnsweredOnTheTicket() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Spacing", description: "More room",
                                       acceptanceCriteria: ["Buttons are spaced", "Which buttons?"], by: alice)
        await sim.signal(.go, "APP-1")

        let waiting = try #require(await sim.node("APP-1"))
        #expect(waiting.flags[.needsInput] != nil)
        #expect(waiting.openQuestions == ["Which buttons?"])
        #expect(waiting.children.isEmpty)
        #expect(await sim.lastComment("APP-1").contains("Which buttons?"))
        await sim.runUntilFinished()
        #expect(await sim.tracker.ticket("APP-1")?.status == "Needs input")

        // Retrying without an answer is refused.
        await sim.signal(.retry, "APP-1")
        #expect(await sim.lastComment("APP-1").contains("in a comment first"))
        #expect(await sim.node("APP-1")?.flags[.needsInput] != nil)

        await sim.tracker.addComment("The play and pause buttons", to: "APP-1", by: alice)
        await sim.signal(.retry, "APP-1")
        let answered = try #require(await sim.node("APP-1"))
        #expect(answered.clarifications == [Clarification(questions: ["Which buttons?"], answer: "The play and pause buttons")])
        #expect(answered.flags[.needsInput] == nil)
        #expect(answered.phase == .proven)
    }

    @Test func aRejectedSignalSaysWhatCanBeDoneInstead() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Spacing", description: "More room",
                                       acceptanceCriteria: ["Buttons are spaced", "Which buttons?"], by: alice)
        await sim.signal(.retry, "APP-1")
        var reply = await sim.lastComment("APP-1")
        #expect(reply.contains("Nothing to retry"))
        #expect(reply.contains("What you can do now:\n- harness:preview"))

        await sim.signal(.go, "APP-1")
        await sim.signal(.breakdown, "APP-1")
        reply = await sim.lastComment("APP-1")
        #expect(reply.contains("Breakdown is already approved"))
        #expect(reply.contains("- Answer the questions in a comment, then harness:retry"))

        await sim.tracker.addComment("The play and pause buttons", to: "APP-1", by: alice)
        await sim.signal(.retry, "APP-1")
        await sim.signal(.retry, "APP-1")
        #expect(await sim.lastComment("APP-1").contains("- Nothing: it's done"))
    }

    @Test func aPreviewsQuestionsCanBeAnsweredInAComment() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Spacing", description: "More room", acceptanceCriteria: ["Buttons are spaced", "Which buttons?"], by: alice)
        await sim.signal(.preview, "APP-1")
        #expect(await sim.tracker.ticket("APP-1")?.comments.contains { $0.text.contains("Answer them in a comment") } == true)

        await sim.tracker.addComment("The play and pause buttons", to: "APP-1", by: alice)
        await sim.signal(.preview, "APP-1")
        #expect(await sim.ledger.workingState().previews["APP-1"] != nil)

        // Adopting keeps the answer for the agents that come later.
        await sim.signal(.go, "APP-1")
        let node = try #require(await sim.node("APP-1"))
        #expect(node.clarifications == [Clarification(questions: ["Which buttons?"], answer: "The play and pause buttons")])
        #expect(node.phase == .proven)
    }

    @Test func aPreviewWithQuestionsRecordsNothing() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Spacing", description: "More room", acceptanceCriteria: ["Which buttons?"], by: alice)
        await sim.signal(.preview, "APP-1")
        #expect(await sim.ledger.workingState().previews["APP-1"] == nil)
        #expect(await sim.tracker.ticket("APP-1")?.comments.contains { $0.text.contains("Which buttons?") } == true)
    }

    @Test func testAuthorQuestionsDiscardTheTestsUntilAnswered() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.tracker.addLabel("sim:ask", to: "APP-1", by: alice)
        await sim.signal(.go, "APP-1")

        let waiting = try #require(await sim.node("APP-1"))
        #expect(waiting.phase == .specified)
        #expect(waiting.openQuestions.count == 1)
        #expect(waiting.testsDigest == nil)

        await sim.tracker.addComment("The start screen", to: "APP-1", by: alice)
        await sim.signal(.retry, "APP-1")
        #expect(await sim.node("APP-1")?.phase == .proven)
    }

    @Test func assumptionsWaitForAReviewOfTheTestsBeforeBuild() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.tracker.addLabel("sim:assume", to: "APP-1", by: alice)
        await sim.signal(.go, "APP-1")

        let waiting = try #require(await sim.node("APP-1"))
        #expect(waiting.phase == .ready)
        #expect(waiting.flags[.needsInput] != nil)
        let posted = await sim.tracker.ticket("APP-1")?.comments.map(\.text) ?? []
        let listing = try #require(posted.first { $0.hasPrefix("🧪") })
        #expect(listing.contains("Says hello"))
        #expect(listing.contains("The facts are checked in every touched component"))

        // harness:build approves the tests as they are, even though build was already approved by go.
        await sim.signal(.build, "APP-1")
        #expect(await sim.node("APP-1")?.phase == .proven)
    }

    @Test func feedbackOnTheTestsHasThemWrittenAgain() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.tracker.addLabel("sim:assume", to: "APP-1", by: alice)
        await sim.signal(.breakdown, "APP-1")
        let firstTests = try #require(await sim.node("APP-1")?.testsDigest)

        await sim.tracker.addComment("Check it in the greeting component only", to: "APP-1", by: alice)
        await sim.signal(.retry, "APP-1")
        let rewritten = try #require(await sim.node("APP-1"))
        #expect(rewritten.testsDigest != firstTests) // written by another run
        #expect(rewritten.clarifications.first?.answer == "Check it in the greeting component only")
        // The test author still assumes, so it waits for another look.
        #expect(rewritten.phase == .ready)
        #expect(rewritten.flags[.needsInput] != nil)
    }

    @Test func autonomousAgentsReportAssumptionsWithoutWaiting() async throws {
        let sim = try Simulation(directory: temporaryDirectory(), team: .scripted, checks: FakeCheckRunner(),
                                 policy: Policy(guesswork: .autonomous))
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.tracker.addLabel("sim:assume", to: "APP-1", by: alice)
        await sim.signal(.go, "APP-1")
        #expect(await sim.node("APP-1")?.phase == .proven)
        #expect(await sim.node("APP-1")?.assumptions[.testAuthor]?.isEmpty == false)
    }

    @Test func underAskAssumptionsAreQuestions() async throws {
        let sim = try Simulation(directory: temporaryDirectory(), team: .scripted, checks: FakeCheckRunner(),
                                 policy: Policy(guesswork: .ask))
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.tracker.addLabel("sim:assume", to: "APP-1", by: alice)
        await sim.signal(.go, "APP-1")
        let waiting = try #require(await sim.node("APP-1"))
        #expect(waiting.phase == .specified)
        #expect(waiting.openQuestions == ["The facts are checked in every touched component"])
    }

    @Test func testNamesAreListedFromSwiftTestingAndXCTest() {
        let source = """
        @Test("Says hello") func criterion1() {}
        @Test
        func unnamed() {}
        final class T: XCTestCase { func testBye() {} }
        """
        #expect(Reconciler.testNames(in: source) == ["Says hello", "unnamed", "testBye"])
    }
}
