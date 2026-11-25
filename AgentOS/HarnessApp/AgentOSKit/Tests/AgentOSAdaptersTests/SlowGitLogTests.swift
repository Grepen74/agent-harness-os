import Foundation
import Testing
@testable import AgentOSAdapters

@Suite("Slow git log")
struct SlowGitLogTests {
    @Test("A git command that took 10 seconds or more is logged with where it ran and the machine's load; a quicker one isn't")
    func slowCommandsAreLogged() throws {
        let storage = FileManager.default.temporaryDirectory.appending(path: "agentos-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let log = SlowGitLog(file: storage.appending(path: "slow-git.log"))
        let worktree = storage.appending(path: "worktrees/wn-1")

        log.record(["status", "--porcelain"], in: worktree, relativeTo: storage, took: .seconds(9), outcome: "exit 0")
        #expect(!FileManager.default.fileExists(atPath: log.file.path))

        log.record(["clean", "-fdq"], in: worktree, relativeTo: storage, took: .milliseconds(121_500), outcome: "timed out")
        let lines = try String(contentsOf: log.file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines.first?.contains(" 121.5s timed out load ") == true, "\(lines)")
        #expect(lines.first?.hasSuffix(": git clean -fdq in worktrees/wn-1") == true, "\(lines)")
    }
}
