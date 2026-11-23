import AgentOSAdapters
import AgentOSCore
import Foundation

public enum WorkflowScenario: Sendable, Equatable, CaseIterable {
    case epicToProven, smallTicketAsLeaf, failureEscalationRetry
    case catchUpConflict, brokenTestReport, batchSplit
}

public struct WorkflowScenarioLedger: Sendable {
    public let scenario: WorkflowScenario
    public let records: [RecordedEvent]

    public init(scenario: WorkflowScenario, records: [RecordedEvent]) {
        self.scenario = scenario
        self.records = records
    }
}

/// Reusable, real reconciler runs for simulation and catalog replay tests. Each invocation
/// owns its disposable simulation directory; returned records need no files to replay.
public enum WorkflowScenarioFixtures {
    public static func ledgers() async throws -> [WorkflowScenarioLedger] {
        var ledgers: [WorkflowScenarioLedger] = []
        for scenario in WorkflowScenario.allCases {
            ledgers.append(try await ledger(for: scenario))
        }
        return ledgers
    }

    public static func ledger(for scenario: WorkflowScenario) async throws -> WorkflowScenarioLedger {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "agentos-workflow-\(UUID().uuidString)")
        do {
            let result = try await run(scenario, in: directory)
            try FileManager.default.removeItem(at: directory)
            return result
        } catch {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            throw error
        }
    }

    private static let person = Participant.human("Scenario author")

    private static func run(_ scenario: WorkflowScenario, in directory: URL) async throws -> WorkflowScenarioLedger {
        var team = AgentTeam.scripted
        if scenario == .brokenTestReport {
            team = AgentTeam(name: "Broken test recovery", decomposer: ScriptedDecomposer(),
                             testAuthor: ScriptedTestAuthor(), implementer: WorkflowReportingImplementer())
        }
        let checks = WorkflowScenarioChecks(splitCombinedBatch: scenario == .batchSplit)
        let sim = try Simulation(
            directory: directory, team: team, checks: checks,
            policy: Policy(maxParallelAgents: scenario == .batchSplit ? 2 : 1))

        switch scenario {
        case .epicToProven:
            await sim.loadDemo()
            try await signal(.preview, "APP-1", in: sim)
            try await signal(.breakdown, "APP-1", in: sim)
            try await signal(.build, "APP-1", in: sim)
            await sim.external.deliver("BACKEND-42")
            try await finish(sim)
        case .smallTicketAsLeaf:
            try await createSmallTicket(in: sim)
            try await signal(.breakdown, "APP-1", in: sim)
            try await signal(.build, "APP-1", in: sim)
        case .failureEscalationRetry:
            try await createSmallTicket(in: sim)
            try await signal(.breakdown, "APP-1", in: sim)
            await sim.tracker.addLabel("sim:always-fail", to: "APP-1", by: person)
            try await signal(.build, "APP-1", in: sim)
            await sim.tracker.removeLabel("sim:always-fail", from: "APP-1")
            try await signal(.retry, "APP-1", in: sim)
        case .catchUpConflict:
            try await createSmallTicket(in: sim)
            try await signal(.go, "APP-1", in: sim)
            // The baseline is an input from the repository monitor. The conflict itself must
            // be produced by the reconciler, not inserted as a synthetic expected answer.
            try await sim.ledger.append([LedgerEvent(node: nil, by: .reconciler, kind: .baselineChecked(
                Baseline(commit: "advanced-main", passed: true, summary: "Baseline passed", seconds: 0, log: nil)))])
            let reconciler = Reconciler(
                ledger: sim.ledger, tracker: LocalTrackerAdapter(tracker: sim.tracker),
                external: sim.external, workspace: sim.workspace,
                artifacts: FileArtifactStore(directory: sim.workspace.artifactsDirectory),
                checks: checks, team: team, requirementBranches: WorkflowConflictingRepository())
            let report = await reconciler.retryRequirementCatchUp()
            if let error = report.safeStop { throw AgentFailure(error) }
        case .brokenTestReport:
            try await createSmallTicket(in: sim)
            try await signal(.go, "APP-1", in: sim)
        case .batchSplit:
            await sim.tracker.createTicket(
                title: "Two features", description: "Independent changes checked together",
                acceptanceCriteria: ["First fact [FirstFeature]", "Second fact [SecondFeature]"], by: person)
            try await signal(.go, "APP-1", in: sim)
        }
        return WorkflowScenarioLedger(scenario: scenario, records: await sim.ledger.allRecords())
    }

    private static func createSmallTicket(in sim: Simulation) async throws {
        await sim.tracker.createTicket(
            title: "Greeting", description: "Say hi", acceptanceCriteria: ["Says hello"], by: person)
    }

    private static func signal(_ command: HarnessCommand, _ ticket: String, in sim: Simulation) async throws {
        await sim.tracker.addLabel(command.label, to: ticket, by: person)
        try await finish(sim)
    }

    private static func finish(_ sim: Simulation) async throws {
        let reports = await sim.runUntilFinished()
        if let error = reports.compactMap(\.safeStop).first { throw AgentFailure(error) }
        guard reports.last?.isIdle == true else {
            throw AgentFailure("Workflow scenario did not reach an idle state within its round budget.")
        }
    }
}
