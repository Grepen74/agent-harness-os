import Foundation
import Testing
@testable import AgentOSCore

@Suite("Harness flow")
struct FlowTests {
    @Test func nothingHappensWithoutASignal() async throws {
        let sim = try makeSimulation()
        await sim.loadDemo()
        await sim.runUntilIdle()
        #expect(await sim.ledger.allRecords().isEmpty)
    }

    @Test func labelsSetByAgentsAreRejected() async throws {
        let sim = try makeSimulation()
        await sim.loadDemo()
        await sim.signal(.breakdown, "APP-1", by: .agent(run: "rogue", role: .implementer))
        #expect(await sim.node("APP-1") == nil)
        #expect(await sim.lastComment("APP-1").contains("Only humans"))
        #expect(await sim.tracker.ticket("APP-1")?.labels.isEmpty == true)
    }

    @Test func ticketsThatAreNotReadyGetAnExplanation() async throws {
        let sim = try makeSimulation()
        await sim.loadDemo()
        await sim.signal(.breakdown, "APP-2")
        #expect(await sim.node("APP-2") == nil)
        #expect(await sim.lastComment("APP-2").contains("acceptance criterion"))
    }

    @Test func previewCreatesNothingAndBreakdownReusesIt() async throws {
        let sim = try makeSimulation()
        await sim.loadDemo()
        await sim.signal(.preview, "APP-1")
        #expect(await sim.node("APP-1") == nil)
        #expect(await sim.tracker.tickets().count == 2)
        let preview = try #require(await sim.ledger.workingState().previews["APP-1"])

        await sim.signal(.breakdown, "APP-1")
        let created = await sim.ledger.workingState().nodes.values.filter { $0.spec.parent == "wn-APP-1" }.map(\.spec)
        #expect(Set(created) == Set(preview.proposal))
    }

    @Test func epicFlowsToProvenOnceTheExternalDependencyIsDelivered() async throws {
        let sim = try makeSimulation()
        await sim.loadDemo()
        await sim.signal(.breakdown, "APP-1")
        await sim.signal(.build, "APP-1")

        let waiting = try #require(await sim.ledger.workingState().nodes.values.first { $0.spec.kind == .leaf && $0.spec.dependsOn == ["BACKEND-42"] })
        #expect(waiting.flags[.blocked] != nil)
        #expect(await sim.node("APP-1")?.phase == .split)

        await sim.external.deliver("BACKEND-42")
        await sim.runUntilIdle()

        let state = await sim.ledger.workingState()
        #expect(state.nodes.count == 4) // the epic and its three leaves
        #expect(state.nodes.values.allSatisfy { $0.phase == .proven })
        #expect(await sim.tracker.ticket("APP-1")?.status == "Done")
        #expect(await sim.ledger.verifyChain().isIntact)

        // Leaves built in parallel from the same main and overlapped in WeatherUI/WeatherService, so some
        // had to be reworked on the latest main. That's not counted as a failed attempt.
        #expect(state.nodes.values.contains { $0.reworks > 0 })
        #expect(state.nodes.values.allSatisfy { $0.failedAttempts == 0 })
        // Everything is on main, combined.
        let service = ScriptedFacts.read(ScriptedFacts.sourceFile("WeatherService", in: sim.workspace.repoDirectory))
        #expect(service["temperature unit"]?.value == "Celsius")
        #expect(service["fetches the forecast from backend-42"]?.value == "yes")
    }

    @Test func aLeafIsProvenOnlyOnceItHasLandedOnMain() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.signal(.breakdown, "APP-1")
        #expect(try await sim.workspace.mainLog().count == 1)

        await sim.signal(.build, "APP-1")
        let leaf = try #require(await sim.node("APP-2"))
        #expect(leaf.phase == .proven)
        let landed = try #require(leaf.landedCommit)
        let log = try await sim.workspace.mainLog()
        #expect(log.first?.hasPrefix(String(landed.prefix(7))) == true)
        #expect(log.first?.contains(leaf.lastSubmission!.run) == true) // the commit is authored by the run that built it
        #expect(leaf.evidence.last?.check.contains("landing") == true)
        #expect(leaf.evidence.last?.builtBy != leaf.evidence.last?.checkedBy)
    }

    @Test func contradictingWorkIsEscalatedAsARequirementsConflict() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Units", description: "Metric", acceptanceCriteria: ["Temperature unit: Celsius [Weather]"], by: alice)
        await sim.signal(.breakdown, "APP-1")
        await sim.signal(.build, "APP-1")
        #expect(await sim.node("APP-1")?.phase == .proven)

        await sim.tracker.createTicket(title: "US", description: "Imperial", acceptanceCriteria: ["Temperature unit: Fahrenheit [Weather]"], by: alice)
        await sim.signal(.breakdown, "APP-3")
        await sim.signal(.build, "APP-3")

        let contradicting = try #require(await sim.node("APP-4"))
        #expect(contradicting.phase != .proven)
        #expect(contradicting.flags[.escalated]?.hasPrefix("Requirements conflict") == true)
        #expect(contradicting.flags[.escalated]?.contains("APP-2") == true)
        #expect(await sim.lastComment("APP-2").contains("APP-4"))
        // main still has the proven behaviour.
        let facts = ScriptedFacts.read(ScriptedFacts.sourceFile("Weather", in: sim.workspace.repoDirectory))
        #expect(facts["temperature unit"]?.value == "Celsius")
    }

    @Test func repeatedFailureEscalatesAndRetryResumes() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.signal(.breakdown, "APP-1")
        await sim.tracker.addLabel("sim:always-fail", to: "APP-2", by: alice)
        await sim.signal(.build, "APP-1")

        let leaf = try #require(await sim.node("APP-2"))
        #expect(leaf.flags[.escalated] != nil)
        #expect(await sim.tracker.ticket("APP-2")?.status == "Needs human")

        // The human "fixes" the problem, then asks the harness to try again.
        await sim.tracker.removeLabel("sim:always-fail", from: "APP-2")
        await sim.signal(.retry, "APP-2")
        #expect(await sim.node("APP-2")?.phase == .proven)
        #expect(await sim.node("APP-1")?.phase == .proven)
    }

    @Test func restartContinuesFromTheLedger() async throws {
        let directory = temporaryDirectory()
        let first = try makeSimulation(directory)
        await first.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await first.signal(.breakdown, "APP-1")
        // Simulate a crash in the middle of a build: the run started but never finished.
        let leaf = try #require(await first.node("APP-2"))
        try await first.ledger.append([
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .runStarted(run: "run-crashed", role: .implementer)),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .building)),
        ])

        let second = try makeSimulation(directory)
        #expect(await second.reconciler.recoverAfterRestart().count == 1)
        await second.signal(.build, "APP-1")
        #expect(await second.node("APP-1")?.phase == .proven)
    }

    @Test func tamperedLedgerStopsTheHarness() async throws {
        let sim = try makeSimulation()
        await sim.loadDemo()
        await sim.signal(.breakdown, "APP-1")
        try await sim.ledger.tamperForDemo()

        await sim.tracker.addLabel(HarnessCommand.build.label, to: "APP-1", by: alice)
        let report = await sim.step()
        #expect(report.safeStop != nil)
        #expect(await sim.tracker.ticket("APP-1")?.labels.isEmpty == false)
    }
}
