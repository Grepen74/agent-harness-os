import Foundation
import Testing
@testable import AgentOSAdapters

@Suite("Simulator pool")
struct SimulatorPoolTests {
    static let command = "xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 14,OS=18.6' -quiet"

    actor FakeProvider: SimulatorProvider {
        let ids: [String]
        private(set) var calls = 0
        init(_ ids: [String]) { self.ids = ids }
        func devices(like destination: SimulatorDestination, count: Int) async -> [String] {
            calls += 1
            return Array(ids.prefix(count))
        }
    }

    /// Which commands run at the same time.
    actor Running {
        private(set) var now: [String] = []
        private(set) var overlaps: [[String]] = []
        func start(_ command: String) { now.append(command); overlaps.append(now) }
        func stop(_ command: String) { now.remove(at: now.firstIndex(of: command)!) }
    }

    func runFour(_ pool: SimulatorPool) async throws -> Running {
        let running = Running()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await pool.withSimulator(for: Self.command) { command in
                        await running.start(command)
                        try await Task.sleep(for: .milliseconds(50))
                        await running.stop(command)
                    }
                }
            }
            try await group.waitForAll()
        }
        return running
    }

    @Test("Checks side by side each get a simulator of their own, made once")
    func eachCheckGetsItsOwnSimulator() async throws {
        let provider = FakeProvider(["A", "B", "C"])
        let running = try await runFour(SimulatorPool(size: 2, provider: provider))

        let overlaps = await running.overlaps
        #expect(overlaps.map(\.count).max() == 2)
        #expect(overlaps.allSatisfy { Set($0).count == $0.count }, "never the same simulator twice at once")
        #expect(Set(overlaps.flatMap { $0 }) == [
            "xcodebuild test -scheme App -destination 'platform=iOS Simulator,id=A' -quiet",
            "xcodebuild test -scheme App -destination 'platform=iOS Simulator,id=B' -quiet",
        ])
        #expect(await provider.calls == 1)
    }

    @Test("The same simulator written two ways is one pool")
    func destinationsAreTheSimulatorNotTheText() async throws {
        let pool = SimulatorPool(size: 1, provider: FakeProvider(["A"]))
        let build = try #require(SimulatorDestination("xcodebuild build -destination \"platform=iOS Simulator,name=iPhone 14,OS=latest\""))
        let test = try #require(SimulatorDestination("xcodebuild test -destination 'platform=iOS Simulator, name=iPhone 14'"))
        let held = await pool.lease(build)

        let running = Running()
        let waiting = Task {
            let device = await pool.lease(test)
            await running.start("test")
            return device
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await running.now.isEmpty, "waits while the build has the simulator")
        await pool.release(held, of: build)

        #expect(await waiting.value == .own("A"))
    }

    @Test("Without simulators of its own, the harness uses the configured one, one check at a time")
    func fallsBackToTheConfiguredSimulatorOneAtATime() async throws {
        let running = try await runFour(SimulatorPool(size: 2, provider: FakeProvider([])))

        let overlaps = await running.overlaps
        #expect(overlaps.map(\.count).max() == 1)
        #expect(Set(overlaps.flatMap { $0 }) == [Self.command])
    }

    @Test("Commands that name no simulator run as written and don't wait for one")
    func onlySimulatorCommandsBorrowOne() async throws {
        let pool = SimulatorPool(size: 1, provider: FakeProvider(["A"]))
        let destination = try #require(SimulatorDestination(Self.command))
        let held = await pool.lease(destination)

        let output = try await pool.withSimulator(for: "swift test") { $0 }

        #expect(output == "swift test")
        await pool.release(held, of: destination)
        let checks = CommandCheckRunner(config: .init(build: .init(command: "echo built"), test: .init(command: "echo \(Self.command)")),
                                        simulators: pool)
        let log = await checks.runChecks(in: FileManager.default.temporaryDirectory, only: nil).log
        #expect(log.contains("$ echo built\n"))
        #expect(log.contains("-destination 'platform=iOS Simulator,id=A' -quiet\n"))
    }

    @Test("The harness's simulators copy the named model and OS, and are reused once made")
    func simctlPlan() throws {
        let json = """
            {"devices": {
              "com.apple.CoreSimulator.SimRuntime.iOS-18-6": [
                {"name": "iPhone 14", "udid": "MINE-18", "deviceTypeIdentifier": "type.iPhone-14"},
                {"name": "AgentOS iPhone 14 (18.6) 1", "udid": "OURS-1", "deviceTypeIdentifier": "type.iPhone-14"}],
              "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
                {"name": "iPhone 14", "udid": "MINE-26", "deviceTypeIdentifier": "type.iPhone-14"}]
            }}
            """
        let list = try JSONDecoder().decode(SimctlProvider.List.self, from: Data(json.utf8))

        let destination = try #require(SimulatorDestination(Self.command))
        let named = try #require(SimctlProvider.plan(list, like: destination, count: 2))
        #expect(named.type == "type.iPhone-14")
        #expect(named.runtime == "com.apple.CoreSimulator.SimRuntime.iOS-18-6")
        #expect(named.devices.map(\.name) == ["AgentOS iPhone 14 (18.6) 1", "AgentOS iPhone 14 (18.6) 2"])
        #expect(named.devices.map(\.id) == ["OURS-1", nil])

        let latest = try #require(SimulatorDestination("xcodebuild -destination 'platform=iOS Simulator,name=iPhone 14'"))
        #expect(SimctlProvider.plan(list, like: latest, count: 1)?.runtime == "com.apple.CoreSimulator.SimRuntime.iOS-26-4")
    }
}
