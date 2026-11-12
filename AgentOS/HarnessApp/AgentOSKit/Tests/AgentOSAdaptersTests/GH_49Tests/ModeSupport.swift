@testable import AgentOSAdapters
import AgentOSCore
import AgentOSSimulation
import Foundation
import Synchronization
import Testing

extension GH_49Tests {
    final class ReadFailureStore: LedgerStore {
        struct State {
            var records: [RecordedEvent] = []
            var failReads = false
        }
        let state = Mutex(State())
        var failReads: Bool {
            get { state.withLock { $0.failReads } }
            set { state.withLock { $0.failReads = newValue } }
        }
        func loadAll() throws -> [RecordedEvent] {
            try state.withLock {
                if $0.failReads { throw LedgerError.unreadable("GH-49 injected read failure") }
                return $0.records
            }
        }
        func append(_ records: [RecordedEvent]) { state.withLock { $0.records += records } }
    }

    static func withSimulation(
        _ body: @Sendable (Simulation, Agents) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gh-49-simulation-\(UUID())")
        let agents = Agents()
        let simulation = try Simulation(directory: directory, team: agents.team, checks: Checks())
        do {
            try await body(simulation, agents)
        } catch {
            agents.releaseAll()
            try await bounded { await simulation.reconciler.shutdown(reason: "GH-49 test cleanup") }
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        agents.releaseAll()
        try await bounded { await simulation.reconciler.shutdown(reason: "GH-49 test cleanup") }
        try FileManager.default.removeItem(at: directory)
    }

    static func withRepository(
        _ body: @Sendable (RepositorySession, Agents, ReadFailureStore) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gh-49-repository-\(UUID())")
        let root = directory.appending(path: "repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let agents = Agents()
        let store = ReadFailureStore()
        let session: RepositorySession
        do {
            try "fixture\n".write(to: root.appending(path: "fixture.txt"), atomically: true, encoding: .utf8)
            try await git(["init", "-q", "-b", "main"], in: root)
            try await git(["add", "fixture.txt"], in: root)
            try await git(["-c", "user.name=GH49", "-c", "user.email=gh49@example.invalid",
                           "commit", "-q", "-m", "fixture"], in: root)
            let commit = try await git(["rev-parse", "HEAD"], in: root)
            let config = RepoConfig(test: .init(command: "unused"),
                                    leafTests: .init(target: "AcceptanceTests", folder: "Tests/AcceptanceTests/"))
            let policy = EffectivePolicy.resolve(harness: HarnessSettings(), repo: config, defaultBranch: "main")
            session = try RepositorySession(
                location: RepositoryLocation(root: root, identity: "gh-49", branch: "main", commit: commit),
                storage: directory.appending(path: "storage"), ledger: Ledger(store: store),
                config: config, policy: policy, team: agents.team, checks: Checks())
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        do {
            try await body(session, agents, store)
        } catch {
            store.failReads = false
            agents.releaseAll()
            try await bounded { await session.reconciler.shutdown(reason: "GH-49 test cleanup") }
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        store.failReads = false
        agents.releaseAll()
        try await bounded { await session.reconciler.shutdown(reason: "GH-49 test cleanup") }
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await bounded {
            try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
        }
        try #require(result.status == 0, "Fixture git command failed: \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
