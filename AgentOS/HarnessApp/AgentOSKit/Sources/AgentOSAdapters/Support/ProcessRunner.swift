import AgentOSCore
import Foundation

/// Runs a command line tool and collects its output.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
    }

    /// - `log`: a file to write the output to as it comes, e.g. to follow it live, which is kept afterwards.
    ///   Without one, the output goes to a temporary file.
    /// - `environment`: added to the cleaned environment, e.g. a token for this one command.
    public static func run(_ executable: String, _ arguments: [String], in directory: URL,
                    timeout: Duration = .seconds(1200), log keptLog: URL? = nil,
                    timeZone: TimeZone = .current,
                    environment extra: [String: String] = [:]) async throws -> Result {
        let logURL = keptLog ?? FileManager.default.temporaryDirectory.appending(path: "agentos-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let outputPipe = Pipe()
        let outputTask = Task {
            try await collectOutput(from: outputPipe.fileHandleForReading, in: logURL, timeZone: timeZone)
        }
        defer {
            outputTask.cancel()
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            if keptLog == nil { try? FileManager.default.removeItem(at: logURL) }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = normalizedArguments(arguments, executable: executable)
        process.currentDirectoryURL = directory
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = FileHandle.nullDevice
        // Run tools with a clean environment: when the app is started from Xcode, its DYLD_* and __XCODE_*
        // variables point at the app's build products and would leak into `swift test` and `git`.
        var environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("__XCODE") && !$0.key.hasPrefix("__XPC_DYLD") }
        // Apps started from Finder get a minimal PATH.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment.merging(extra) { $1 }

        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        defer { timeoutTask.cancel() }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            // Install this before launch: a short-lived child can otherwise exit during handler registration.
            process.terminationHandler = { terminatedProcess in
                continuation.resume(returning: terminatedProcess.terminationStatus)
            }
            do {
                try process.run()
                try? outputPipe.fileHandleForWriting.close()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        let output = try await outputTask.value
        return Result(status: status, output: output)
    }

    private static func collectOutput(from handle: FileHandle, in log: URL,
                                      timeZone: TimeZone) async throws -> String {
        var output = Data()
        var line = Data()
        for try await byte in handle.bytes {
            output.append(byte)
            if byte == 0x0A {
                AgentLog.append(String(decoding: line, as: UTF8.self), to: log,
                                producedAt: .now, timeZone: timeZone)
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        if !line.isEmpty {
            AgentLog.append(String(decoding: line, as: UTF8.self), to: log,
                            producedAt: .now, timeZone: timeZone)
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func normalizedArguments(_ arguments: [String], executable: String) -> [String] {
        guard executable == "/usr/bin/env",
              arguments.first == "git",
              let command = arguments.firstIndex(of: "cherry-pick"),
              arguments.indices.contains(command + 1),
              arguments[command + 1] == "-q"
        else {
            return arguments
        }
        var result = arguments
        result.remove(at: command + 1)
        return result
    }
}
