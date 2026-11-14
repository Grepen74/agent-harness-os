import AgentOSCore
import Foundation
import Observation

/// Display-only history, independent of complete indexed agent-run history.
@Observable @MainActor
public final class LedgerPageModel {
    public private(set) var limit = 200
    public private(set) var totalCount = 0
    public private(set) var matchingCount = 0
    public private(set) var nodeIDs: [NodeID] = []
    public let eventKinds = LedgerEventKind.allCases
    public private(set) var records: [RecordedEvent] = []
    public private(set) var selectedNode: NodeID?
    public private(set) var selectedKind: LedgerEventKind?
    public var canShowOlder: Bool { records.count < matchingCount }
    @ObservationIgnored private var source: (any LedgerPageSource)?
    @ObservationIgnored private var ledgerID: UUID?
    @ObservationIgnored private var requestID = UUID()

    public init() {}

    public func showOlder() async {
        guard canShowOlder else { return }
        limit += 200
        await reload()
    }

    public func selectNode(_ node: NodeID?) async {
        guard node != selectedNode else { return }
        selectedNode = node
        limit = 200
        await reload()
    }

    public func selectKind(_ kind: LedgerEventKind?) async {
        guard kind != selectedKind else { return }
        selectedKind = kind
        limit = 200
        await reload()
    }

    func invalidate() {
        requestID = UUID()
        source = nil
        ledgerID = nil
        limit = 200
        selectedNode = nil
        selectedKind = nil
        totalCount = 0
        matchingCount = 0
        nodeIDs = []
        records = []
    }

    func refresh(from source: any LedgerPageSource) async {
        let request = UUID()
        requestID = request
        let identity = await source.ledgerID
        guard requestID == request else { return }
        if ledgerID != identity {
            invalidate()
            requestID = request
            ledgerID = identity
        }
        self.source = source
        let snapshot = await source.pageSnapshot(node: selectedNode, kind: selectedKind, limit: limit)
        guard requestID == request, snapshot.ledgerID == ledgerID else { return }
        totalCount = snapshot.totalCount
        matchingCount = snapshot.matchingCount
        nodeIDs = snapshot.nodeIDs
        records = snapshot.records
    }

    private func reload() async {
        guard let source else { return }
        await refresh(from: source)
    }
}
