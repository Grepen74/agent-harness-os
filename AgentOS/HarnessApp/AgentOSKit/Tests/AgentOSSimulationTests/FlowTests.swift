import Foundation
import Testing
import AgentOSAdapters
import AgentOSCore
@testable import AgentOSSimulation

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

    @Test func aSmallTicketIsItsOwnLeaf() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.signal(.breakdown, "APP-1")

        let node = try #require(await sim.node("APP-1"))
        #expect(node.spec.kind == .leaf)
        #expect(node.children.isEmpty)
        #expect(await sim.tracker.tickets().count == 1)
        #expect(node.testsDigest != nil) // went straight on to its acceptance tests
    }

    @Test func breakdownOnALeafIsRejected() async throws {
        let sim = try makeSimulation()
        await sim.loadDemo()
        await sim.signal(.breakdown, "APP-1")
        let leaf = try #require(await sim.ledger.workingState().nodes.values.first { $0.spec.parent == "wn-APP-1" })

        await sim.signal(.breakdown, leaf.ticket)
        #expect(await sim.lastComment(leaf.ticket).contains("is a leaf"))
        #expect(await sim.node(leaf.ticket)?.gates.isEmpty == true)
    }

    @Test func goBreaksDownBuildsAndChecksInOneSignal() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello", "Says bye"], by: alice)
        await sim.signal(.go, "APP-1")

        let state = await sim.ledger.workingState()
        #expect(state.nodes.count == 3)
        #expect(state.nodes.values.allSatisfy { $0.phase == .proven })
    }

    @Test func signalsTheProfileDoesNotOfferAreRejected() async throws {
        let sim = try Simulation(directory: temporaryDirectory(), team: .scripted, checks: FakeCheckRunner(),
                                 policy: Policy(allowedSignals: [.preview, .breakdown, .build, .retry]))
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.signal(.go, "APP-1")
        #expect(await sim.node("APP-1") == nil)
        #expect(await sim.lastComment("APP-1").contains("isn't enabled"))
    }

    @Test func aLeafIsProvenOnlyOnceItHasLandedOnMain() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.signal(.breakdown, "APP-1")
        #expect(try await sim.workspace.mainLog().count == 1)

        await sim.signal(.build, "APP-1")
        let leaf = try #require(await sim.node("APP-1"))
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
        await sim.signal(.breakdown, "APP-2")
        await sim.signal(.build, "APP-2")

        let contradicting = try #require(await sim.node("APP-2"))
        #expect(contradicting.phase != .proven)
        #expect(contradicting.flags[.escalated]?.hasPrefix("Requirements conflict") == true)
        #expect(contradicting.flags[.escalated]?.contains("APP-1") == true)
        #expect(await sim.lastComment("APP-1").contains("APP-2"))
        // main still has the proven behaviour.
        let facts = ScriptedFacts.read(ScriptedFacts.sourceFile("Weather", in: sim.workspace.repoDirectory))
        #expect(facts["temperature unit"]?.value == "Celsius")
    }

    @Test func repeatedFailureEscalatesAndRetryResumes() async throws {
        let sim = try makeSimulation()
        await sim.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await sim.signal(.breakdown, "APP-1")
        await sim.tracker.addLabel("sim:always-fail", to: "APP-1", by: alice)
        await sim.signal(.build, "APP-1")

        let leaf = try #require(await sim.node("APP-1"))
        #expect(leaf.flags[.escalated] != nil)
        #expect(await sim.tracker.ticket("APP-1")?.status == "Needs human")

        // The human "fixes" the problem, then asks the harness to try again.
        await sim.tracker.removeLabel("sim:always-fail", from: "APP-1")
        await sim.signal(.retry, "APP-1")
        #expect(await sim.node("APP-1")?.phase == .proven)
    }

    @Test func restartContinuesFromTheLedger() async throws {
        let directory = temporaryDirectory()
        let first = try makeSimulation(directory)
        await first.tracker.createTicket(title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: alice)
        await first.signal(.breakdown, "APP-1")
        // Simulate a crash in the middle of a build: the run started but never finished.
        let leaf = try #require(await first.node("APP-1"))
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
        try await sim.tamperWithLedgerForDemo()

        await sim.tracker.addLabel(HarnessCommand.build.label, to: "APP-1", by: alice)
        let report = await sim.step()
        #expect(report.safeStop != nil)
        #expect(await sim.tracker.ticket("APP-1")?.labels.isEmpty == false)

        #expect(try await sim.restoreLedgerAfterTamperDemo())
        #expect(try await makeSimulation(sim.directory).ledger.verifyChain().isIntact)
    }

    @Test func tamperDuringARoundStillRestoresAnIntactLedger() async throws {
        let sim = try makeSimulation()
        await sim.loadDemo()
        await sim.signal(.preview, "APP-1")
        await sim.tracker.addLabel(HarnessCommand.breakdown.label, to: "APP-1", by: alice)

        async let round = sim.step()
        try await sim.tamperWithLedgerForDemo()
        _ = await round

        #expect(try await sim.restoreLedgerAfterTamperDemo())
        #expect(try await makeSimulation(sim.directory).ledger.verifyChain().isIntact)
    }
}
