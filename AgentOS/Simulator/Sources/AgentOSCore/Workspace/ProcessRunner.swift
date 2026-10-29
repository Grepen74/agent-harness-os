import Foundation

/// Runs a command line tool and collects its output.
enum ProcessRunner {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    /// Small wrapper so the process can be terminated from the timeout task.
    private final class Box: @unchecked Sendable {
        let process = Process()
    }

    static func run(_ executable: String, _ arguments: [String], in directory: URL,
                    timeout: Duration = .seconds(1200)) async throws -> Result {
        let logURL = FileManager.default.temporaryDirectory.appending(path: "agentos-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }

        let box = Box()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        // Apps started from Finder get a minimal PATH.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment

        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            if box.process.isRunning { box.process.terminate() }
        }
        defer { timeoutTask.cancel() }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return Result(status: status, output: output)
    }
}
