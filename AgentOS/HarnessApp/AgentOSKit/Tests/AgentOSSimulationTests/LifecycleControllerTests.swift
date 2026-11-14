import AgentOSAdapters
import AgentOSCore
import Testing

@MainActor
@Suite("Harness lifecycle")
struct LifecycleControllerTests {
    @Test("Pause ends Run but lets the round under way finish uncancelled; shutdown cancels it")
    func pauseLeavesTheRoundUnderWayAlone() async throws {
        let sim = try makeSimulation()
        let paused = HarnessLifecycleController(reconciler: sim.reconciler, interval: .milliseconds(10))
        let round = RoundProbe()
        paused.runStep = { await round.run() }
        paused.setRunning(true)
        try await until { await round.started }
        paused.setRunning(false)
        await round.release()
        try await until { await round.cancelled != nil }
        #expect(await round.cancelled == false)

        let shutDown = HarnessLifecycleController(reconciler: sim.reconciler, interval: .milliseconds(10))
        let stopped = RoundProbe()
        shutDown.runStep = { await stopped.run() }
        shutDown.setRunning(true)
        try await until { await stopped.started }
        await shutDown.shutdown(reason: "window closed")
        try await until { await stopped.cancelled != nil }
        #expect(await stopped.cancelled == true)
    }

    private actor RoundProbe {
        private(set) var started = false
        private(set) var cancelled: Bool?
        private var released = false
        func run() async {
            started = true
            while !released, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            cancelled = Task.isCancelled
        }
        func release() { released = true }
    }

    private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 where !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await condition())
    }
}
