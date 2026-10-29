import AgentOSAdapters
import AgentOSCore
import Foundation

/// Demo only: edit the ledger file behind the harness's back, then recover.
/// Use through `Simulation`, which serializes these with ledger appends.
extension FileLedgerStore {
    private var backupURL: URL { fileURL.appendingPathExtension("before-tamper") }

    /// Back-dates one stored event, as someone editing the database directly might.
    func tamperForDemo() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        var lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return }
        // Keep the first untouched copy, so the demo can recover (see `restoreAfterTamperDemo`).
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
        let index = lines.count / 2
        guard var object = try JSONSerialization.jsonObject(with: Data(lines[index].utf8)) as? [String: Any],
              var event = object["event"] as? [String: Any] else { return }
        event["at"] = "2001-01-01T00:00:00Z"
        object["event"] = event
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        lines[index] = String(decoding: data, as: UTF8.self)
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Puts back the copy saved before tampering. Returns false if there is nothing to restore.
    /// Production: a human investigates, then restores from a replica or backup whose last hash matches
    /// the anchor kept outside the ledger. The harness never repairs its own ledger.
    /// Reload the ledger afterwards (restart the harness) so memory matches the restored file.
    func restoreAfterTamperDemo() throws -> Bool {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return false }
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: backupURL)
        return true
    }
}
