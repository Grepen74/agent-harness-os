import Foundation
import Testing
@testable import AgentOSCore

let alice = Participant.human("Alice")

@Suite("Ledger")
struct LedgerTests {
    let spec = NodeSpec(id: "wn-1", parent: nil, kind: .leaf, title: "T", intent: "I", acceptanceCriteria: ["a"])

    @Test func retriedEventsAreRecordedOnce() async throws {
        let ledger = try Ledger()
        let event = LedgerEvent(node: spec.id, by: alice, kind: .nodeCreated(spec: spec, ticket: "APP-1"))
        try await ledger.append([event])
        try await ledger.append([event])
        #expect(await ledger.allRecords().count == 1)
    }

    @Test func refusesWritesBasedOnStaleState() async throws {
        let ledger = try Ledger()
        try await ledger.append([LedgerEvent(node: spec.id, by: alice, kind: .nodeCreated(spec: spec, ticket: "APP-1"))])
        let seen = await ledger.workingState().nodes[spec.id]!.version
        try await ledger.append([LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .ready))])

        await #expect(throws: LedgerError.self) {
            try await ledger.append([LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .building))],
                                    expecting: [spec.id: seen])
        }
    }

    @Test func builderCannotCheckOwnWork() async throws {
        let ledger = try Ledger()
        let evidence = Evidence(check: "swift test", passed: true, summary: "ok", specHash: "x", builtBy: "run-1",
                                checkedBy: "run-1", artifactPath: "", artifactSHA256: "", commit: "abc123")
        await #expect(throws: LedgerError.self) {
            try await ledger.append([LedgerEvent(node: spec.id, by: .agent(run: "run-1", role: .verifier), kind: .evidenceRecorded(evidence))])
        }
    }

    @Test func onlyHumansOpenGates() async throws {
        let ledger = try Ledger()
        await #expect(throws: LedgerError.self) {
            try await ledger.append([LedgerEvent(node: spec.id, by: .reconciler, kind: .gateOpened(.build))])
        }
    }
}
