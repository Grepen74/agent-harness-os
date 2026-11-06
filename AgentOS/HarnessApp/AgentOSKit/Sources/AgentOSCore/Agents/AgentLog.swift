import Foundation

/// An agent run's own output, written to a file while it runs so you can follow it live, and kept afterwards
/// next to the check logs. The ledger records only that the run started and finished; the file is named after
/// the node and run, so it can be found from those events.
public enum AgentLog {
    public static func fileName(node: NodeID, run: RunID) -> String { "\(node)-\(run)-agent.log" }

    /// Appends a line, e.g. what a scripted agent did. Does nothing without a log file.
    public static func append(_ line: String, to url: URL?) {
        guard let url, let data = (line + "\n").data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
