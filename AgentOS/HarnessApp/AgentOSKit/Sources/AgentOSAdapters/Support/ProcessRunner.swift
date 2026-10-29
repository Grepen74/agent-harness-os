import Foundation

/// Runs a command line tool and collects its output.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
    }

    /// Small wrapper so the process can be terminated from the timeout task.
    private final class Box: @unchecked Sendable {
        let process = Process()
    }

    public static func run(_ executable: String, _ arguments: [String], in directory: URL,
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
        // Run tools with a clean environment: when the app is started from Xcode, its DYLD_* and __XCODE_*
        // variables point at the app's build products and would leak into `swift test` and `git`.
        var environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("__XCODE") && !$0.key.hasPrefix("__XPC_DYLD") }
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
