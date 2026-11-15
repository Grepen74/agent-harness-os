import Darwin
import Foundation

/// A tool you talk to a line at a time on stdin and stdout, e.g. an Agent Client Protocol server. It runs in its
/// own process group, so stopping it also stops whatever it started.
final class LineProcess: @unchecked Sendable {
    /// What the tool writes to stdout, a line at a time; it ends when the tool closes its output.
    let lines: AsyncStream<String>
    private let pid: pid_t
    private let input: FileHandle
    private let errors: URL
    private let reader: Task<Void, Never>
    private let lock = NSLock()
    private var stopped = false

    static func start(_ executable: String, _ arguments: [String], in directory: URL,
                      environment: [String: String]) throws -> LineProcess {
        let stdin = Pipe()
        let stdout = Pipe()
        let errors = FileManager.default.temporaryDirectory.appending(path: "agentos-\(UUID().uuidString).stderr")
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        try ProcessRunner.checkPOSIX(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try ProcessRunner.checkPOSIX(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try ProcessRunner.checkPOSIX(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try ProcessRunner.checkPOSIX(posix_spawnattr_setpgroup(&attributes, 0))
        try ProcessRunner.checkPOSIX(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        try ProcessRunner.checkPOSIX(posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, STDIN_FILENO))
        try ProcessRunner.checkPOSIX(posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try ProcessRunner.checkPOSIX(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, errors.path,
                                                                      O_WRONLY | O_CREAT | O_TRUNC, 0o600))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
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
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        guard error == 0 else {
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        // Writing after the tool has gone fails instead of raising SIGPIPE, which would end the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        return LineProcess(pid: pid, input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading, errors: errors)
    }

    private init(pid: pid_t, input: FileHandle, output: FileHandle, errors: URL) {
        self.pid = pid
        self.input = input
        self.errors = errors
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.lines = lines
        reader = Task.detached {
            do {
                for try await line in output.bytes.lines { continuation.yield(line) }
            } catch {}
            continuation.finish()
            try? output.close()
        }
    }

    func send(_ line: String) throws {
        try input.write(contentsOf: Data((line + "\n").utf8))
    }

    /// What the tool wrote to stderr so far, at most `limit` characters from the end.
    func errorOutput(limit: Int = 2000) -> String {
        let text = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
        return String(text.suffix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Closes the tool's input, gives it a moment to exit, then kills its process group and reaps it. It finishes even
    /// when the caller is cancelled, and never blocks a thread waiting for the tool.
    func stop(grace: Duration = .seconds(1)) async {
        let first = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        guard first else { return }
        try? input.close()
        // A new task isn't cancelled with the caller, so the grace period really waits.
        await Task { await self.finish(grace: grace) }.value
    }

    private func finish(grace: Duration) async {
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline, !hasExited() {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // The process isn't reaped yet, so its group can't have been reused by another process.
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while true {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid || (reaped == -1 && errno != EINTR) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        reader.cancel()
        try? FileManager.default.removeItem(at: errors)
    }

    private func hasExited() -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }
}
