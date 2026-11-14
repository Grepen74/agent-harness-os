/// Complete history captured in one actor turn, unaffected by subsequent appends.
public struct LedgerHistorySnapshot: Sendable {
    public let records: [RecordedEvent]
    private let recordsByNode: [NodeID: [RecordedEvent]]

    init(records: [RecordedEvent], recordsByNode: [NodeID: [RecordedEvent]]) {
        self.records = records
        self.recordsByNode = recordsByNode
    }

    public func records(for node: NodeID) -> [RecordedEvent] { recordsByNode[node] ?? [] }
}
