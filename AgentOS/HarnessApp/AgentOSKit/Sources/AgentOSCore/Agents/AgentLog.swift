import Foundation

/// An agent run's own output, written to a file while it runs so you can follow it live, and kept afterwards
/// next to the check logs. The ledger records only that the run started and finished; the file is named after
/// the node and run, so it can be found from those events.
public enum AgentLog {
    public static func fileName(node: NodeID, run: RunID) -> String { "\(node)-\(run)-agent.log" }

    /// Appends output without decoration. Kept for callers that use an agent log as raw command output.
    public static func append(_ line: String, to url: URL?) {
        write(line + (line.hasSuffix("\n") ? "" : "\n"), to: url)
    }

    /// Appends physical lines with the time they were produced. Does nothing without a log file.
    public static func append(_ line: String, to url: URL?, producedAt: Date, timeZone: TimeZone) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        let prefix = "[\(formatter.string(from: producedAt))] "
        var lines = line.components(separatedBy: "\n")
        if line.hasSuffix("\n") { lines.removeLast() }
        let rendered = lines.map { prefix + $0 }.joined(separator: "\n") + "\n"
        write(rendered, to: url)
    }

    /// In one `O_APPEND` write, so lines from several writers at once (parallel git commands, say) don't overwrite
    /// each other.
    private static func write(_ text: String, to url: URL?) {
        guard let url else { return }
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            bytes = bytes.dropFirst(written)
        }
    }
}
