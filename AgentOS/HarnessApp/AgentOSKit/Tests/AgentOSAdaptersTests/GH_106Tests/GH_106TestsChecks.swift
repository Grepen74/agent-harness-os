import AgentOSCore
import Foundation
import Testing

extension GH_106Tests {
    actor RecordingChecks: CheckRunner {
        struct Call: Sendable {
            let observation: RecordingWorkspace.Observation
            let only: String?
            let proven: Set<NodeID>
            let landedComments: Set<NodeID>
        }

        let mode: Mode
        let ids: [NodeID]
        let workspace: RecordingWorkspace
        let ledger: Ledger
        let tracker: RecordingTracker
        private var fullRuns: [String: Int] = [:]
        private(set) var calls: [Call] = []

        init(mode: Mode, ids: [NodeID], workspace: RecordingWorkspace, ledger: Ledger, tracker: RecordingTracker) {
            self.mode = mode
            self.ids = ids
            self.workspace = workspace
            self.ledger = ledger
            self.tracker = tracker
        }

        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            let observation: RecordingWorkspace.Observation
            do { observation = try await workspace.observation(in: directory) }
            catch {
                Issue.record("The checks fixture received an unknown checkout: \(error)")
                return CheckOutput(passed: false, summary: "Unknown checkout", log: "\(error)")
            }
            let state = await ledger.workingState()
            calls.append(Call(observation: observation, only: testTarget,
                              proven: Set(state.nodes.values.filter { $0.phase == .proven }.map(\.id)),
                              landedComments: await tracker.landedIDs()))
            if mode == .passing { return Self.pass }

            if mode == .owners {
                let owners = [ids[0], ids[2]].filter(observation.contents.contains)
                if !owners.isEmpty {
                    return Self.fail(Set(owners.map(Self.target)), only: testTarget)
                }
                return Self.pass
            }

            let provenTarget = Self.target(Fixture.provenID)
            let loadTarget = mode == .memberOwnedUnderLoad || mode == .memberOwnedDisturbs
                ? Self.target(Fixture.badID) : provenTarget
            if observation.nodes.isEmpty {
                // Multi-node diagnostics select a different suite from the eventual singleton.
                if testTarget == "UnownedBatchTests" { return Self.pass }
                if mode == .batchInfrastructure || (mode == .infrastructure && testTarget != nil) {
                    return Self.fail([testTarget ?? provenTarget])
                }
                if mode == .batchEmptySelection || (mode == .emptySelection && testTarget != nil) {
                    return CheckOutput(passed: true, summary: "No selected tests", log: "Test run with 0 tests passed.")
                }
                if (mode == .underLoad || mode == .memberOwnedUnderLoad) && testTarget == nil {
                    return Self.fail([loadTarget])
                }
                return Self.pass
            }
            guard observation.contents.contains(Fixture.badID) else { return Self.pass }
            let key = observation.nodes.joined(separator: ",")
            if testTarget == nil { fullRuns[key, default: 0] += 1 }
            let attempt = fullRuns[key, default: 0]

            if observation.nodes.count > 1 {
                switch mode {
                case .batchInfrastructure, .batchEmptySelection:
                    return Self.fail([Self.target(ids[0])], only: testTarget)
                case .mixedOwnership:
                    return Self.fail([Self.target(Fixture.badID), provenTarget], only: testTarget)
                case .mixedUnknownOwnership:
                    return Self.fail([Self.target(Fixture.badID), "UnownedBatchTests"], only: testTarget)
                case .requirementsConflict:
                    return Self.fail([provenTarget], only: testTarget)
                case .underLoad, .disturbs, .memberOwnedUnderLoad, .memberOwnedDisturbs:
                    return testTarget == nil ? Self.fail([loadTarget]) : Self.pass
                default:
                    // This combination breaks an unowned test; only the bad singleton keeps failing.
                    return Self.fail(["UnownedBatchTests"], only: testTarget)
                }
            }

            switch mode {
            case .ownRework, .ownWithoutPrecheck, .ownRerun, .attemptLimit, .mixedUnknownOwnership:
                return Self.fail([Self.target(Fixture.badID)], only: testTarget)
            case .mixedOwnership:
                return Self.fail([Self.target(Fixture.badID), provenTarget], only: testTarget)
            case .runnerCrash: return Self.crash
            case .underLoad, .disturbs, .memberOwnedUnderLoad, .memberOwnedDisturbs:
                return testTarget == nil ? Self.fail([loadTarget]) : Self.pass
            case .retryPasses:
                return attempt > 1 ? Self.pass : Self.fail([provenTarget], only: testTarget)
            case .requirementsConflict, .infrastructure, .emptySelection:
                return Self.fail([provenTarget], only: testTarget)
            default:
                return Self.fail(["UnownedBatchTests"], only: testTarget)
            }
        }

        private static func target(_ id: NodeID) -> String {
            Fixture.spec(id, parent: nil).testTarget
        }
        private static var pass: CheckOutput {
            CheckOutput(passed: true, summary: "All selected checks passed", log: "Test run with 3 tests passed.")
        }
        private static var crash: CheckOutput {
            CheckOutput(passed: false, summary: "Fixture runner interrupted", log: "Runner exited with signal 9",
                        failureKind: .runnerCrash(signal: 9))
        }
        private static func fail(_ targets: Set<String>, only: String? = nil) -> CheckOutput {
            let selected = only.map { targets.intersection([$0]) } ?? targets
            guard !selected.isEmpty else { return pass }
            return CheckOutput(
                passed: false, summary: "Behavior failed in \(selected.sorted().joined(separator: ", "))",
                log: selected.sorted().map {
                    "Test preservedBehavior() recorded an issue at \($0).swift:10:1: Expectation failed"
                }.joined(separator: "\n"), failingTargets: selected
            )
        }
    }
}
