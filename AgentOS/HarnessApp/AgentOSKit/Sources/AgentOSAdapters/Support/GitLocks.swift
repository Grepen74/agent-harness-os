import Darwin
import Foundation

/// Lock files that a killed git left behind, e.g. when a timeout or quitting the app ended it mid-write.
/// Git keeps a lock file open while it holds it, so a lock nobody has open is stale.
public enum GitLocks {
    /// Runs a git command and, if it failed only because of a stale lock file, removes the lock and runs it once more.
    public static func retryingAfterStaleLock(
        _ run: () async throws -> ProcessRunner.Result
    ) async throws -> ProcessRunner.Result {
        let result = try await run()
        guard result.status != 0, let lock = lockPath(in: result.output), removeIfStale(lock) else { return result }
        return try await run()
    }

    /// The lock file named in git's "Unable to create '….lock': File exists." error.
    static func lockPath(in output: String) -> URL? {
        guard let start = output.range(of: "Unable to create '"),
              let end = output.range(of: ".lock': File exists", range: start.upperBound..<output.endIndex)
        else { return nil }
        return URL(filePath: String(output[start.upperBound..<end.lowerBound]) + ".lock")
    }

    /// Removes `lock` unless some process still has it open or it was only just created.
    @discardableResult
    static func removeIfStale(_ lock: URL, minimumAge: TimeInterval = 2) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: lock.path),
              let modified = attributes[.modificationDate] as? Date,
              Date.now.timeIntervalSince(modified) >= minimumAge,
              !isOpen(lock)
        else { return false }
        return (try? FileManager.default.removeItem(at: lock)) != nil
    }

    static func isOpen(_ file: URL) -> Bool {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = pids.withUnsafeMutableBytes {
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, file.path, 0, $0.baseAddress, Int32($0.count))
        }
        // When the check itself fails, assume the lock is held: removing a live lock would corrupt the index.
        return count != 0
    }
}
