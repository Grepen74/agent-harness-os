import AgentOSCore
import Darwin
import Foundation

/// Runs a command line tool and collects its output.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public let crashSignal: Int32?
        public let idleTimedOut: Bool
    }

    /// - `log`: a file to write the output to as it comes, e.g. to follow it live, which is kept afterwards.
    ///   Without one, the output goes to a temporary file.
    /// - `environment`: added to the cleaned environment, e.g. a token for this one command.
    public static func run(_ executable: String, _ arguments: [String], in directory: URL,
                    timeout: Duration = .seconds(1200), log keptLog: URL? = nil,
                    environment extra: [String: String] = [:], idleTimeout: Duration? = nil) async throws -> Result {
        try await run(executable, arguments, in: directory, timeout: timeout, log: keptLog,
                      timeZone: nil, environment: extra, logPreamble: "", idleTimeout: idleTimeout)
    }

    /// Runs a command and timestamps each persisted output line in the supplied time zone.
    public static func run(_ executable: String, _ arguments: [String], in directory: URL,
                    timeout: Duration = .seconds(1200), log keptLog: URL? = nil,
                    timeZone: TimeZone,
                    environment extra: [String: String] = [:], logPreamble: String = "") async throws -> Result {
        try await run(executable, arguments, in: directory, timeout: timeout, log: keptLog,
                      timeZone: Optional(timeZone), environment: extra, logPreamble: logPreamble, idleTimeout: nil)
    }

    private static func run(_ executable: String, _ arguments: [String], in directory: URL,
                    timeout: Duration, log keptLog: URL?, timeZone: TimeZone?,
                    environment extra: [String: String], logPreamble: String, idleTimeout: Duration?) async throws -> Result {
        try Task.checkCancellation()
        let logURL = keptLog ?? FileManager.default.temporaryDirectory.appending(path: "agentos-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data(logPreamble.utf8))
        let outputPipe = Pipe()
        let activity = OutputActivity()
        let outputTask = Task {
            try await collectOutput(from: outputPipe.fileHandleForReading, in: logURL, timeZone: timeZone, activity: activity)
        }
        defer {
            outputTask.cancel()
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            if keptLog == nil { try? FileManager.default.removeItem(at: logURL) }
        }

        // Run tools with a clean environment: when the app is started from Xcode, its DYLD_* and __XCODE_*
        // variables point at the app's build products and would leak into `swift test` and `git`.
        var environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("__XCODE") && !$0.key.hasPrefix("__XPC_DYLD") }
        // Apps started from Finder get a minimal PATH.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        environment.merge(extra) { $1 }

        // A private process group also catches descendants whose immediate parent exits between polls.
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        try checkPOSIX(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checkPOSIX(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checkPOSIX(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try checkPOSIX(posix_spawnattr_setpgroup(&attributes, 0))
        try checkPOSIX(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        try checkPOSIX(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try checkPOSIX(posix_spawn_file_actions_adddup2(&actions, outputPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try checkPOSIX(posix_spawn_file_actions_adddup2(&actions, outputPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
        let argv = ([executable] + normalizedArguments(arguments, executable: executable)).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp { if let pointer { free(pointer) } }
        }
        var pid: pid_t = 0
        let error = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        try checkPOSIX(error)
        var processError: (any Error)?
        do { try outputPipe.fileHandleForWriting.close() }
        catch { processError = error }

        let started = ContinuousClock.now
        var descendants: [OwnedProcess] = []
        var status: Int32 = 0
        var idleTimedOut = false
        var endedEarly = false
        while true {
            for child in processTree(below: pid) where !descendants.contains(child) { descendants.append(child) }
            // Observe exit without reaping yet: reserving the PID keeps its process group ours until cleanup.
            var exitInfo = siginfo_t()
            if waitid(P_PID, id_t(pid), &exitInfo, WEXITED | WNOHANG | WNOWAIT) == -1, errno != EINTR {
                processError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if exitInfo.si_pid == pid { break }
            idleTimedOut = if let idleTimeout { await activity.idleTime >= idleTimeout } else { false }
            if processError != nil || Task.isCancelled || ContinuousClock.now - started >= timeout || idleTimedOut {
                endedEarly = true
                break
            }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { endedEarly = true; break }
        }
        let ownedPID = pid
        let ownedDescendants = descendants
        // Cleanup is intentionally uncancelled. Parents must stay alive long enough to reap their children.
        await Task {
            for child in ownedDescendants.reversed() {
                guard child.isAlive else { continue }
                kill(child.pid, SIGKILL)
                let deadline = ContinuousClock.now + .milliseconds(300)
                while child.isAlive, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            kill(-ownedPID, SIGKILL)
        }.value
        while true {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { break }
            if reaped == -1, errno != EINTR {
                processError = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                break
            }
            await Task { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        await Task {
            while kill(-ownedPID, 0) == 0 || ownedDescendants.contains(where: \.isAlive) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }.value
        var output = try await outputTask.value
        try Task.checkCancellation()
        if let processError { throw processError }
        if endedEarly && !idleTimedOut {
            let diagnostic = "Timed out after \(timeout)"
            output += "\n\(diagnostic)\n"
            append(diagnostic, to: logURL, producedAt: .now, timeZone: timeZone)
        }
        let signal = status & 0x7f
        return Result(
            status: endedEarly ? SIGKILL : (signal == 0 ? (status >> 8) & 0xff : signal),
            output: output,
            crashSignal: endedEarly ? SIGKILL : (signal == 0 ? nil : signal),
            idleTimedOut: idleTimedOut
        )
    }

    private static func checkPOSIX(_ result: Int32) throws {
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }

    private struct OwnedProcess: Sendable, Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        init?(_ pid: pid_t) {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            self.pid = pid
            startSeconds = info.pbi_start_tvsec
            startMicroseconds = info.pbi_start_tvusec
        }

        var isAlive: Bool { Self(pid) == self }
    }

    private static func processTree(below parent: pid_t) -> [OwnedProcess] {
        let bytes = proc_listchildpids(parent, nil, 0)
        guard bytes > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 32)
        let size = children.count * MemoryLayout<pid_t>.size
        let filled = children.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32(size)) }
        guard filled > 0 else { return [] }
        let direct = children.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 1 }
        return direct.compactMap(OwnedProcess.init) + direct.flatMap { processTree(below: $0) }
    }

    private actor OutputActivity {
        var lastOutput = ContinuousClock.now
        func producedOutput() { lastOutput = .now }
        var idleTime: Duration { ContinuousClock.now - lastOutput }
    }

    private static func collectOutput(from handle: FileHandle, in log: URL,
                                      timeZone: TimeZone?, activity: OutputActivity) async throws -> String {
        var output = Data()
        var line = Data()
        var lastProducedAt = Date.now
        for await chunk in chunks(from: handle) {
            await activity.producedOutput()
            output.append(chunk.data)
            lastProducedAt = chunk.producedAt
            for byte in chunk.data {
                if byte == 0x0A {
                    append(
                        String(decoding: line, as: UTF8.self),
                        to: log,
                        producedAt: chunk.producedAt,
                        timeZone: timeZone
                    )
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
        }
        if !line.isEmpty {
            append(
                String(decoding: line, as: UTF8.self),
                to: log,
                producedAt: lastProducedAt,
                timeZone: timeZone
            )
        }
        return String(decoding: output, as: UTF8.self)
    }

    private struct OutputChunk: Sendable {
        let data: Data
        let producedAt: Date
    }

    private static func chunks(from handle: FileHandle) -> AsyncStream<OutputChunk> {
        AsyncStream { continuation in
            handle.readabilityHandler = { readableHandle in
                let data = readableHandle.availableData
                guard !data.isEmpty else {
                    readableHandle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                continuation.yield(OutputChunk(data: data, producedAt: .now))
            }
            continuation.onTermination = { @Sendable _ in
                handle.readabilityHandler = nil
            }
        }
    }

    private static func append(_ line: String, to log: URL, producedAt: Date,
                               timeZone: TimeZone?) {
        if let timeZone {
            AgentLog.append(line, to: log, producedAt: producedAt, timeZone: timeZone)
        } else {
            AgentLog.append(line, to: log)
        }
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
