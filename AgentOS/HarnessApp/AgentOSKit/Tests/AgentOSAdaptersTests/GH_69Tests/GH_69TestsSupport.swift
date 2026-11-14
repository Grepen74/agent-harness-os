import Foundation
import Testing
import AgentOSCore

extension GH_69Tests {
    actor GH69HeldPageSource: HarnessLedgerRefreshSource {
        private enum Failure: Error { case requestTimedOut }

        private let ledger: Ledger
        private let requested: AsyncStream<Void>
        private let requestedSignal: AsyncStream<Void>.Continuation
        private let released: AsyncStream<Void>
        private let releasedSignal: AsyncStream<Void>.Continuation

        init(ledger: Ledger) {
            self.ledger = ledger
            (requested, requestedSignal) = AsyncStream<Void>.makeStream()
            (released, releasedSignal) = AsyncStream<Void>.makeStream()
        }

        var ledgerID: UUID { get async { await ledger.ledgerID } }

        func historySnapshot() async -> LedgerHistorySnapshot { await ledger.historySnapshot() }

        func records(after position: Int, limit: Int) async -> [RecordedEvent] {
            await ledger.records(after: position, limit: limit)
        }

        func workingState() async -> WorkingState { await ledger.workingState() }

        func pageSnapshot(node: NodeID?, kind: LedgerEventKind?, limit: Int) async -> LedgerPageSnapshot {
            let snapshot = await ledger.pageSnapshot(node: node, kind: kind, limit: limit)
            requestedSignal.yield(())
            requestedSignal.finish()
            let signal = releasedSignal
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { signal.finish() }
            for await _ in released { return snapshot }
            Issue.record("Timed out waiting for the test to release the old ledger snapshot")
            return snapshot
        }

        nonisolated func waitUntilRequested() async throws {
            let signal = requestedSignal
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { signal.finish() }
            for await _ in requested { return }
            throw Failure.requestTimedOut
        }

        nonisolated func release() {
            releasedSignal.yield(())
            releasedSignal.finish()
        }
    }
}
