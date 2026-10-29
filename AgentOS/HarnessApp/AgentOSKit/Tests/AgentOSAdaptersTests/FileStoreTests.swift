import AgentOSAdapters
@testable import AgentOSCore
import Foundation
import Testing

@Suite("File stores")
struct FileStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "agentos-tests-\(UUID().uuidString)")
    let spec = NodeSpec(id: "wn-1", parent: nil, kind: .leaf, title: "T", intent: "I", acceptanceCriteria: ["a"])

    @Test func ledgerReloadsStateFromDisk() async throws {
        let store = FileLedgerStore(fileURL: directory.appending(path: "ledger.jsonl"))
        try await Ledger(store: store).append([
            LedgerEvent(node: spec.id, by: .human("Alice"), kind: .nodeCreated(spec: spec, ticket: "APP-1")),
            LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
        ])

        let reloaded = try Ledger(store: store)
        #expect(await reloaded.workingState().nodes[spec.id]?.phase == .ready)
        #expect(await reloaded.verifyChain().isIntact)
    }

    @Test func localTrackerKeepsTicketsAcrossRestarts() async throws {
        let store = FileTicketStore(fileURL: directory.appending(path: "tracker.json"))
        let key = await LocalTracker(store: store).createTicket(
            title: "Weather widget", description: "", acceptanceCriteria: ["Shows °C"], by: .human("Alice")).key
        await LocalTracker(store: store).addLabel("harness:preview", to: key, by: .human("Alice"))

        let ticket = try #require(await LocalTracker(store: store).ticket(key))
        #expect(ticket.acceptanceCriteria == ["Shows °C"])
        #expect(ticket.labels.map(\.name) == ["harness:preview"])
    }
}
