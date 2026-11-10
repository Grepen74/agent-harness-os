import Foundation

/// An agent run's own output, written to a file while it runs so you can follow it live, and kept afterwards
/// next to the check logs. The ledger records only that the run started and finished; the file is named after
/// the node and run, so it can be found from those events.
public enum AgentLog {
    public static func fileName(node: NodeID, run: RunID) -> String { "\(node)-\(run)-agent.log" }

    /// Appends physical lines with the time they were produced. Does nothing without a log file.
    public static func append(_ line: String, to url: URL?, producedAt: Date = .now,
                              timeZone: TimeZone = .current) {
        guard let url else { return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        let prefix = "[\(formatter.string(from: producedAt))] "
        var lines = line.components(separatedBy: "\n")
        if line.hasSuffix("\n") { lines.removeLast() }
        let rendered = lines.map { prefix + $0 }.joined(separator: "\n") + "\n"
        guard let data = rendered.data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
