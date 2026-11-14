import Foundation

public struct LedgerVerificationStatistics: Sendable {
    public let decodedRecords: Int
    public let hashedRecords: Int
}

/// Only a successful storage check advances the anchor. Failures latch until a full check succeeds.
struct LedgerVerification {
    var checkpoint: LedgerStorageCheckpoint?
    var terminalHash = RecordedEvent.genesisHash
    var failure: ChainReport?
    var decodedRecords = 0
    var hashedRecords = 0

    mutating func check(_ read: LedgerStorageRead, expectedCount: Int) -> ChainReport {
        decodedRecords += read.decodedRecords
        var previousHash = read.startPosition == 0 ? RecordedEvent.genesisHash : terminalHash
        for (offset, record) in read.records.enumerated() {
            hashedRecords += 1
            guard record.isIntact else {
                return fail(position: record.position,
                            reason: "record content doesn't match its hash (changed after writing)")
            }
            guard record.position == read.startPosition + offset,
                  record.previousHash == previousHash else {
                return fail(position: record.position,
                            reason: "chain broken: record doesn't follow the one before")
            }
            previousHash = record.hash
        }
        guard read.checkpoint.recordCount == expectedCount else {
            return fail(position: read.checkpoint.recordCount,
                        reason: "\(expectedCount - read.checkpoint.recordCount) records missing from storage")
        }
        checkpoint = read.checkpoint
        terminalHash = previousHash
        failure = nil
        return ChainReport(checked: read.checkpoint.recordCount, problem: nil)
    }

    mutating func fail(position: Int = -1, reason: String) -> ChainReport {
        let report = ChainReport(checked: max(0, position), problem: .init(position: position, reason: reason))
        failure = report
        return report
    }
}
