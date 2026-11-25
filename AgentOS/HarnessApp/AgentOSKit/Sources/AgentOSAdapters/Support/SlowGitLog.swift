import AgentOSCore
import Darwin
import Foundation

/// A line for each git command that took a while, to tell what makes git slow: the machine's load, or something
/// about one working copy (its size, untracked files…). `<storage>/slow-git.log`.
struct SlowGitLog: Sendable {
    let file: URL
    static let threshold: Duration = .seconds(10)

    /// Times `command` and logs it if it took at least the threshold, including when it was cut off.
    func timing(_ arguments: [String], in directory: URL, relativeTo storage: URL,
                _ command: () async throws -> ProcessRunner.Result) async throws -> ProcessRunner.Result {
        let started = ContinuousClock.now
        do {
            let result = try await command()
            record(arguments, in: directory, relativeTo: storage, took: ContinuousClock.now - started,
                   outcome: result.crashSignal == SIGKILL ? "timed out" : "exit \(result.status)")
            return result
        } catch {
            record(arguments, in: directory, relativeTo: storage, took: ContinuousClock.now - started, outcome: "\(error)")
            throw error
        }
    }

    func record(_ arguments: [String], in directory: URL, relativeTo storage: URL, took duration: Duration,
                outcome: String) {
        guard duration >= Self.threshold else { return }
        var load = [Double](repeating: 0, count: 3)
        let loads = getloadavg(&load, 3) == 3 ? load.map { String(format: "%.1f", $0) }.joined(separator: " ") : "?"
        let storagePath = storage.standardizedFileURL.path + "/"
        let place = directory.standardizedFileURL.path.hasPrefix(storagePath)
            ? String(directory.standardizedFileURL.path.dropFirst(storagePath.count)) : directory.path
        let command = arguments.prefix(8)
            .map { $0.count > 80 ? $0.prefix(80) + "…" : $0 }.joined(separator: " ")
        let seconds = String(format: "%.1f", Double(duration.components.seconds)
                             + Double(duration.components.attoseconds) / 1e18)
        AgentLog.append("\(Date.now.ISO8601Format()) \(seconds)s \(outcome) load \(loads): git \(command) in \(place)",
                        to: file)
    }
}
