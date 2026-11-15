import Foundation

public struct LedgerPageSnapshot: Sendable {
    public let ledgerID: UUID
    public let totalCount: Int
    public let matchingCount: Int
    public let nodeIDs: [NodeID]
    public let records: [RecordedEvent]

    public init(ledgerID: UUID, totalCount: Int, matchingCount: Int,
                nodeIDs: [NodeID], records: [RecordedEvent]) {
        self.ledgerID = ledgerID
        self.totalCount = totalCount
        self.matchingCount = matchingCount
        self.nodeIDs = nodeIDs
        self.records = records
    }
}

public protocol LedgerPageSource: Sendable {
    var ledgerID: UUID { get async }
    func pageSnapshot(node: NodeID?, kind: LedgerEventKind?, limit: Int) async -> LedgerPageSnapshot
}

public protocol HarnessLedgerRefreshSource: LedgerPageSource {
    func historySnapshot() async -> LedgerHistorySnapshot
    func records(after position: Int, limit: Int) async -> [RecordedEvent]
    func workingState() async -> WorkingState
}
