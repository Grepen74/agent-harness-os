import Foundation
import Testing
@testable import AgentOSAdapters

@Suite struct GitLocksTests {
    private func repository() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gitlocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for arguments in [["init", "-q"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "start"]] {
            let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
            #expect(result.status == 0)
        }
        return directory
    }

    private func leaveLock(at lock: URL) throws {
        FileManager.default.createFile(atPath: lock.path, contents: nil)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-60)], ofItemAtPath: lock.path)
    }

    @Test func aLockLeftByAKilledGitIsRemovedAndTheCommandRetried() async throws {
        let directory = try await repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appending(path: ".git/index.lock")
        try leaveLock(at: lock)

        let result = try await GitLocks.retryingAfterStaleLock {
            try await ProcessRunner.run("/usr/bin/env", ["git", "reset", "-q", "--hard"], in: directory)
        }

        #expect(result.status == 0)
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test func aLockAProcessStillHoldsIsLeftAlone() async throws {
        let directory = try await repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appending(path: ".git/index.lock")
        try leaveLock(at: lock)
        let holder = Process()
        holder.executableURL = URL(filePath: "/bin/sh")
        holder.arguments = ["-c", "exec 3>>'\(lock.path)'; sleep 30"]
        try holder.run()
        defer { holder.terminate() }
        let deadline = Date.now.addingTimeInterval(5)
        while !GitLocks.isOpen(lock), Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }

        let result = try await GitLocks.retryingAfterStaleLock {
            try await ProcessRunner.run("/usr/bin/env", ["git", "reset", "-q", "--hard"], in: directory)
        }

        #expect(result.status != 0)
        #expect(FileManager.default.fileExists(atPath: lock.path))
    }
}
