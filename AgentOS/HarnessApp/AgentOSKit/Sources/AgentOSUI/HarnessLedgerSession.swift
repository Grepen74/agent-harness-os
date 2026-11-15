import AgentOSCore
import Foundation

/// Shared refresh and replacement boundary for repository and simulator windows.
@MainActor public final class HarnessLedgerSession {
    private let view: HarnessViewModel
    private var source: any HarnessLedgerRefreshSource
    private var ledgerID: UUID?
    private var position = -1
    private var refreshID = UUID()

    public init(view: HarnessViewModel, source: any HarnessLedgerRefreshSource) {
        self.view = view
        self.source = source
    }

    public func refresh() async {
        let request = UUID()
        refreshID = request
        let source = source
        let identity = await source.ledgerID
        guard refreshID == request else { return }
        if ledgerID != identity {
            ledgerID = identity
            position = -1
            view.records = []
            view.ledgerPage.invalidate()
        }
        await view.refreshLedger(from: source)
        guard refreshID == request else { return }
        // A filter or paging request can supersede the display refresh without updating its count.
        let snapshot = await source.pageSnapshot(node: nil, kind: nil, limit: 200)
        guard refreshID == request else { return }
        let target = snapshot.totalCount - 1
        var cursor = position
        var newRecords: [RecordedEvent] = []
        while cursor < target {
            let batch = await source.records(after: cursor, limit: min(200, target - cursor))
            guard refreshID == request else { return }
            precondition(!batch.isEmpty, "Ledger history ended before its snapshot position")
            newRecords.append(contentsOf: batch)
            cursor = batch.last!.position
        }
        let state = await source.workingState()
        guard refreshID == request else { return }
        view.appendHistory(newRecords)
        position = cursor
        view.state = state
    }

    public func reset(to source: any HarnessLedgerRefreshSource) async { await replace(with: source) }
    public func restart(from source: any HarnessLedgerRefreshSource) async { await replace(with: source) }
    public func restore(from source: any HarnessLedgerRefreshSource) async { await replace(with: source) }

    private func replace(with source: any HarnessLedgerRefreshSource) async {
        refreshID = UUID()
        self.source = source
        ledgerID = nil
        position = -1
        view.records = []
        view.state = WorkingState()
        view.ledgerPage.invalidate()
        await refresh()
    }
}
