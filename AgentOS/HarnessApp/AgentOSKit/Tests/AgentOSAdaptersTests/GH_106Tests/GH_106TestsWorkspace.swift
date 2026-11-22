import AgentOSCore
import Foundation
import Testing

extension GH_106Tests {
    actor RecordingWorkspace: Workspace {
        struct Observation: Sendable {
            let nodes: [NodeID]
            let base: [NodeID]
            var contents: [NodeID] { base + nodes }
        }

        nonisolated let root: URL
        private var observations: [URL: Observation] = [:]
        private var heads: [URL: String] = [:]
        private var checkpoints: [String: Observation] = [:]
        private var specs: [NodeID: NodeSpec] = [:]
        private var tip: [NodeID] = []
        private var tipCommit = "requirement-base"
        private(set) var landings: [[NodeID]] = []

        init(root: URL) { self.root = root }

        func seed(_ spec: NodeSpec) throws {
            specs[spec.id] = spec
            let directory = worktree(for: spec.id)
            try writeTests(in: directory)
            observations[directory] = Observation(nodes: [spec.id], base: [])
        }

        private func writeTests(in directory: URL) throws {
            for spec in specs.values {
                let folder = directory.appending(path: testFolder(for: spec))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try "fixed tests for \(spec.id)\n".write(to: folder.appending(path: "Acceptance.swift"),
                                                       atomically: true, encoding: .utf8)
            }
        }

        func observation(in directory: URL) throws -> Observation {
            try #require(observations[directory], "Checks must run in a known candidate or requirement snapshot")
        }

        nonisolated var supportsLandingBatches: Bool { true }

        func createLandingBatch(for nodes: [NodeID]) async throws -> LandingBatchWorkspace {
            let directory = root.appending(path: "batches/\(UUID())")
            try writeTests(in: directory)
            let current = Observation(nodes: [], base: tip)
            observations[directory] = current
            heads[directory] = tipCommit
            checkpoints[tipCommit] = current
            let baseCommit = tipCommit
            var members: [LandingBatchMember] = []
            for node in nodes {
                let checkpoint = try await head(of: directory)
                _ = try await applyToLandingBatch(node, in: directory)
                members.append(LandingBatchMember(
                    node: node, commit: try await head(of: directory),
                    changedFiles: try await changedFiles(in: directory, since: checkpoint)
                ))
            }
            return LandingBatchWorkspace(
                directory: directory, branch: "agentos/GH-106-REQ", baseCommit: baseCommit,
                candidateCommit: try await head(of: directory), members: members
            )
        }

        func applyToLandingBatch(_ node: NodeID, in directory: URL) async throws -> RebaseResult {
            let current = try observation(in: directory)
            let applied = Observation(nodes: current.nodes + [node], base: current.base)
            let commit = current.nodes.isEmpty ? Fixture.commit(node)
                : "\(try await head(of: directory))+\(Fixture.commit(node))"
            observations[directory] = applied
            heads[directory] = commit
            checkpoints[commit] = applied
            return .clean
        }

        func resetLandingBatch(_ directory: URL, to commit: String) async throws {
            observations[directory] = try #require(checkpoints[commit], "Reset needs a known candidate checkpoint")
            heads[directory] = commit
        }

        func changedFiles(in directory: URL, since commit: String) async throws -> [String] {
            let before = try #require(checkpoints[commit], "The protected-tests check needs a known checkpoint")
            return try observation(in: directory).nodes.filter { !before.nodes.contains($0) }
                .map { "Sources/\($0).swift" }
        }

        func landBatch(_ batch: LandingBatchWorkspace) async throws -> LandingBatchMove {
            let nodes = batch.members.map(\.node)
            let current = try observation(in: batch.directory)
            try #require(current.base == tip, "A split candidate must be based on the latest requirement tip")
            guard batch.baseCommit == tipCommit else { return .branchMoved }
            try #require(current.nodes == nodes, "Removed owners must not contaminate the landed candidate")
            try #require(try await head(of: batch.directory) == batch.candidateCommit,
                         "Land the exact candidate that was checked")
            tip += nodes
            landings.append(nodes)
            tipCommit = batch.candidateCommit
            return .landed
        }

        func prepare() async throws {}
        func prepareRequirementBranch(for requirement: NodeIdentity, leaves: [NodeID]) async throws -> String? { nil }
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: "leaves/\(id)") }
        func createWorktree(for id: NodeID) async throws -> URL { worktree(for: id) }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            try await head(of: directory)
        }
        func head(of directory: URL) async throws -> String {
            if let commit = heads[directory] { return commit }
            return try observation(in: directory).contents.last.map(Fixture.commit) ?? "requirement-base"
        }
        func changedFiles(in directory: URL) async throws -> [String] {
            try observation(in: directory).nodes.map { "Sources/\($0).swift" }
        }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            let current = try observation(in: directory)
            observations[directory] = Observation(nodes: current.nodes, base: tip)
            return .clean
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            let current = try observation(in: worktree(for: id))
            try #require(current.base == tip)
            tip.append(id)
            landings.append([id])
            tipCommit = Fixture.commit(id)
            return tipCommit
        }
        nonisolated func existingComponents() -> [String] { [] }
        func prepareBuild(in directory: URL) async throws {}
        func createSnapshot(for id: NodeID) async throws -> URL? {
            let directory = root.appending(path: "snapshots/\(UUID())")
            try writeTests(in: directory)
            observations[directory] = Observation(nodes: [], base: tip)
            heads[directory] = tipCommit
            return directory
        }
        func removeSnapshot(_ directory: URL) async {}
    }
}
