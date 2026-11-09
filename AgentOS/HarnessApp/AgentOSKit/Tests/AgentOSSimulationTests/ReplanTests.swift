import Foundation
import Testing
import AgentOSAdapters
@testable import AgentOSCore
@testable import AgentOSSimulation

@Suite("Replan")
struct ReplanTests {
    private func childTickets(of key: String, in sim: Simulation) async -> [String] {
        let state = await sim.ledger.workingState()
        guard let node = state.node(forTicket: key) else { return [] }
        return node.children.compactMap { state.nodes[$0]?.ticket }.sorted()
    }

    private let celsius = "Temperature unit: Celsius [WeatherService, WeatherUI]"
    private let icon = "Shows an icon matching the weather condition [WeatherUI]"
    private let forecast = "Fetches the forecast from BACKEND-42 [WeatherAPIClient, WeatherService]"

    @Test func aForgottenDependencyKeepsTheWholeBreakdownAndHoldsItsLeaves() async throws {
        let sim = try makeSimulation()
        await sim.loadDemo()
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.signal(.breakdown, "APP-1")
        let old = await childTickets(of: "APP-1", in: sim)
        let tests = await sim.ledger.workingState().nodes.values.filter { $0.spec.parent == "wn-APP-1" }.map(\.testsDigest)
        #expect(old.count == 3)

        await sim.tracker.edit("APP-1", title: "Weather widget", description: "At a glance",
                               acceptanceCriteria: [celsius, icon, forecast], blockedBy: ["BACKEND-42", "APP-3"])
        await sim.signal(.replan, "APP-1")
        let node = try #require(await sim.node("APP-1"))
        #expect(node.phase == .specified && node.gates.isEmpty)
        #expect(node.spec.dependsOn == ["BACKEND-42", "APP-3"])
        #expect(await sim.lastComment("APP-1").contains("are paused"))

        await sim.signal(.breakdown, "APP-1")
        #expect(await childTickets(of: "APP-1", in: sim) == old)
        let kept = await sim.ledger.workingState().nodes.values.filter { $0.spec.parent == "wn-APP-1" }.map(\.testsDigest)
        #expect(Set(kept) == Set(tests))
        #expect(await sim.tracker.ticket("APP-1")?.comments.contains { $0.text.contains("Kept from the old breakdown") } == true)

        await sim.signal(.build, "APP-1")
        for key in old { #expect(await sim.node(key)?.flags[.blocked]?.contains("APP-3") == true) }
    }

    @Test func aChangedBreakdownKeepsWhatsUnchangedAndClosesTheRest() async throws {
        let sim = try makeSimulation()
        await sim.loadDemo()
        await sim.signal(.breakdown, "APP-1")
        let state = await sim.ledger.workingState()
        let byCriterion = { (criterion: String) in
            state.nodes.values.first { $0.spec.parent == "wn-APP-1" && criterion.hasPrefix($0.spec.title) }!.ticket
        }
        let (celsiusTicket, iconTicket) = (byCriterion(celsius), byCriterion(icon))

        await sim.tracker.edit("APP-1", title: "Weather widget", description: "At a glance",
                               acceptanceCriteria: [celsius, "Shows the wind speed [WeatherUI]", forecast], blockedBy: ["BACKEND-42"])
        await sim.signal(.replan, "APP-1")

        // Until the new breakdown, the old children wait, even with their own approval.
        await sim.signal(.build, celsiusTicket)
        #expect(await sim.node(celsiusTicket)?.phase == .ready)
        await sim.signal(.retry, celsiusTicket)
        #expect(await sim.lastComment(celsiusTicket).contains("APP-1 was replanned"))

        await sim.signal(.breakdown, "APP-1")
        let children = await childTickets(of: "APP-1", in: sim)
        #expect(children.count == 3)
        #expect(children.contains(celsiusTicket))
        #expect(!children.contains(iconTicket))
        #expect(await sim.node(iconTicket) == nil)
        #expect(await sim.tracker.ticket(iconTicket)?.status == "Superseded")
        #expect(await sim.lastComment(iconTicket).contains("Superseded: APP-1 was replanned"))
        let ids = await sim.ledger.workingState().nodes.values.filter { $0.spec.parent == "wn-APP-1" }.map(\.id)
        #expect(Set(ids).count == 3)

        // A signal on a dropped ticket is refused, rather than adopting it as a new ticket.
        await sim.signal(.breakdown, iconTicket)
        #expect(await sim.node(iconTicket) == nil)
        #expect(await sim.lastComment(iconTicket).contains("- Nothing: it was dropped when APP-1 was replanned"))
    }

    @Test func replanIsRefusedOnAChildAndOnceBuildingHasStarted() async throws {
        let sim = try makeSimulation()
        await sim.loadDemo()
        await sim.signal(.breakdown, "APP-1")
        let child = try #require(await childTickets(of: "APP-1", in: sim).first)
        await sim.signal(.breakdown, "APP-1")
        #expect(await sim.lastComment("APP-1").contains("- harness:replan to redo its plan"))

        await sim.signal(.replan, child)
        #expect(await sim.lastComment(child).contains("Replan APP-1 instead"))

        await sim.signal(.build, "APP-1")
        await sim.signal(.replan, "APP-1")
        #expect(await sim.lastComment("APP-1").contains("Building has started"))
        #expect(await childTickets(of: "APP-1", in: sim).count == 3)
    }

    @Test func aTicketBlockedByAnotherWaitsUntilThatOneIsProven() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.tracker.createTicket(title: "Farewell", description: "Say bye", acceptanceCriteria: ["Says goodbye"],
                                       blockedBy: ["APP-1"], by: alice)
        await sim.signal(.go, "APP-2")
        #expect(await sim.node("APP-2")?.flags[.blocked] == "Waiting for APP-1")

        await sim.signal(.go, "APP-1")
        await sim.runUntilIdle()
        #expect(await sim.node("APP-1")?.phase == .proven)
        #expect(await sim.node("APP-2")?.phase == .proven)
    }
}
