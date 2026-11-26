import AgentOSCore
import Foundation

public struct LedgerCutBack: Sendable, Equatable {
    public let keptRecords: Int
    public let movedRecords: Int
    public let movedTo: URL
}

extension FileLedgerStore {
    /// A person's repair of a broken ledger: keeps the first records that form an intact chain and moves every
    /// line after them, unchanged, to `ledger.removed-<time>.jsonl` beside the ledger. Nil when nothing is broken.
    /// Call while nothing appends (`Ledger.exclusively`), then open a new `Ledger` on the file.
    public func cutBackToIntactPart(now: Date = .now) throws -> LedgerCutBack? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let lines = try Data(contentsOf: fileURL).split(separator: 0x0A)
        let decoder = Hashing.decoder()
        var records: [RecordedEvent] = []
        for line in lines {
            guard let record = try? decoder.decode(RecordedEvent.self, from: Data(line)) else { break }
            records.append(record)
        }
        let kept = Ledger.intactPrefixCount(of: records)
        guard kept < lines.count else { return nil }

        let stamp = now.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .dateSeparator(.omitted).timeSeparator(.omitted))
        let movedTo = fileURL.deletingLastPathComponent().appending(path: "ledger.removed-\(stamp).jsonl")
        try Self.joined(lines[kept...]).write(to: movedTo, options: .withoutOverwriting)
        try Self.joined(lines[..<kept]).write(to: fileURL, options: .atomic)
        return LedgerCutBack(keptRecords: kept, movedRecords: lines.count - kept, movedTo: movedTo)
    }

    private static func joined(_ lines: ArraySlice<Data.SubSequence>) -> Data {
        var data = Data()
        for line in lines {
            data.append(contentsOf: line)
            data.append(0x0A)
        }
        return data
    }
}
