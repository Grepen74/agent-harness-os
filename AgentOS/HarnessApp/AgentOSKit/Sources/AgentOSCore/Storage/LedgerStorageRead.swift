import Foundation

/// An anchor for a verified storage prefix, independent of individual record hashes.
public struct LedgerStorageCheckpoint: Sendable {
    public let recordCount: Int
    public let byteCount: Int
    public let digest: String

    public init(recordCount: Int, bytes: Data) {
        self.recordCount = recordCount
        byteCount = bytes.count
        digest = Hashing.sha256(bytes)
    }

    public func validatePrefix(in bytes: Data) throws {
        guard bytes.count >= byteCount,
              Hashing.sha256(Data(bytes.prefix(byteCount))) == digest else {
            throw LedgerError.unreadable("chain broken: verified storage prefix changed or was truncated")
        }
    }
}

/// Records and the storage anchor captured from the same read.
public struct LedgerStorageRead: Sendable {
    public let records: [RecordedEvent]
    public let startPosition: Int
    public let checkpoint: LedgerStorageCheckpoint
    public let decodedRecords: Int

    public init(records: [RecordedEvent], startPosition: Int,
                checkpoint: LedgerStorageCheckpoint, decodedRecords: Int) {
        self.records = records
        self.startPosition = startPosition
        self.checkpoint = checkpoint
        self.decodedRecords = decodedRecords
    }

    static func bytes(for records: [RecordedEvent]) -> Data {
        var bytes = Data()
        for record in records {
            bytes.append(Hashing.canonicalJSON(record))
            bytes.append(0x0A)
        }
        return bytes
    }
}

extension LedgerStore {
    /// Compatibility stores retain full-read verification without adopting the optimized API.
    public func readForVerification(after checkpoint: LedgerStorageCheckpoint?) throws -> LedgerStorageRead {
        let records = try loadAll()
        let bytes = LedgerStorageRead.bytes(for: records)
        try checkpoint?.validatePrefix(in: bytes)
        return LedgerStorageRead(
            records: records, startPosition: 0,
            checkpoint: LedgerStorageCheckpoint(recordCount: records.count, bytes: bytes),
            decodedRecords: records.count)
    }
}
