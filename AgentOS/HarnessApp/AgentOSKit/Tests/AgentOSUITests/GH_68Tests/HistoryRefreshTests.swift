import AgentOSCore
import Testing
@testable import AgentOSUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HistoryRefreshTests {
    @Test func anAppendCannotSplitLegacyAndIndexedSnapshots() async throws {
        let ledger = try Ledger()
        let node: NodeID = "history-node"
        try await ledger.append([
            LedgerEvent(node: node, by: .reconciler, kind: .runStarted(run: "builder", role: .implementer))
        ])
        let snapshot = await ledger.historySnapshot()
        try await ledger.append([
            LedgerEvent(node: node, by: .reconciler, kind: .runFinished(run: "builder", outcome: "submitted"))
        ])
        let model = HarnessViewModel()
        await model.refreshHistory { snapshot }
        #expect(model.records.map(\.hash) == model.records(for: node).map(\.hash))
        #expect(AgentRuns.runs(of: node, in: model).map(\.outcome) == [nil])
        await model.refreshHistory(from: ledger)
        #expect(AgentRuns.runs(of: node, in: model).map(\.outcome) == ["submitted"])
        #expect(model.records.map(\.hash) == model.records(for: node).map(\.hash))
    }

    @Test(arguments: [false, true])
    func aSuspendedRefreshCannotReplaceNewerHistory(replaceLedger: Bool) async throws {
        let ledger = try Ledger()
        let node: NodeID = "history-node"
        try await ledger.append([
            LedgerEvent(node: node, by: .reconciler, kind: .runStarted(run: "old", role: .implementer))
        ])
        let oldSnapshot = await ledger.historySnapshot()
        let model = HarnessViewModel()
        var release: CheckedContinuation<LedgerHistorySnapshot, Never>?
        let (started, signal) = AsyncStream<Void>.makeStream()
        let stale = Task { @MainActor in
            await model.refreshHistory {
                await withCheckedContinuation { continuation in
                    release = continuation
                    signal.yield()
                    signal.finish()
                }
            }
        }
        for await _ in started { break }
        if replaceLedger {
            await model.refreshHistory(from: try Ledger())
        } else {
            try await ledger.append([
                LedgerEvent(node: node, by: .reconciler, kind: .runFinished(run: "old", outcome: "submitted"))
            ])
            await model.refreshHistory(from: ledger)
        }
        release?.resume(returning: oldSnapshot)
        await stale.value
        #expect(AgentRuns.runs(of: node, in: model).map(\.outcome) == (replaceLedger ? [] : ["submitted"]))
        #expect(model.records.map(\.hash) == model.records(for: node).map(\.hash))
    }

    @Test func assigningLegacyRecordsInvalidatesASuspendedRefresh() async throws {
        let ledger = try Ledger()
        try await ledger.append([
            LedgerEvent(node: "old-node", by: .reconciler, kind: .attemptsReset)
        ])
        let snapshot = await ledger.historySnapshot()
        let model = HarnessViewModel()
        var release: CheckedContinuation<LedgerHistorySnapshot, Never>?
        let (started, signal) = AsyncStream<Void>.makeStream()
        let stale = Task { @MainActor in
            await model.refreshHistory {
                await withCheckedContinuation { continuation in
                    release = continuation
                    signal.yield()
                    signal.finish()
                }
            }
        }
        for await _ in started { break }
        model.records = []
        release?.resume(returning: snapshot)
        await stale.value
        #expect(model.records.isEmpty)
        #expect(model.records(for: "old-node").isEmpty)
    }
}
