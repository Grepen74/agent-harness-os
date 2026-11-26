import AgentOSCore
import Foundation
import Testing

extension GH_161Tests {
    actor RecordingWorkspace: Workspace {
        nonisolated let root: URL
        let ownership: Ownership
        let definitions: [Definition]
        private var candidates: [URL: [NodeID]] = [:]
        private var bases: [URL: [NodeID]] = [:]
        private var heads: [URL: String] = [:]
        private var tip: [NodeID] = []
        private var tipCommit = "requirement-base"
        private(set) var landings: [[NodeID]] = []

        init(root: URL, ownership: Ownership, definitions: [Definition]) {
            self.root = root
            self.ownership = ownership
            self.definitions = definitions
        }

        func seed(_ spec: NodeSpec) throws {
            let directory = worktree(for: spec.id)
            try writeTests(in: directory)
            candidates[directory] = [spec.id]
            bases[directory] = []
            heads[directory] = Fixture.commit(spec.id)
        }

        private func writeTests(in directory: URL) throws {
            for definition in definitions {
                var sources = ownership.sources(for: definition)
                for file in definition.files ?? [] where sources[file] == nil {
                    sources[file] = "// Recorded helper\n"
                }
                let legacy = testFolder(for: definition.spec(parent: nil)) + "/Acceptance.swift"
                sources[legacy] = "// Fixed legacy tests\n"
                for (file, contents) in sources {
                    let url = directory.appending(path: file)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }

        func nodes(in directory: URL) throws -> [NodeID] {
            try #require(candidates[directory], "Checks must run in a candidate or baseline snapshot")
        }

        nonisolated var supportsLandingBatches: Bool { true }
        func createLandingBatch(for nodes: [NodeID]) async throws -> LandingBatchWorkspace {
            let directory = root.appending(path: "batches/\(UUID())")
            try writeTests(in: directory)
            candidates[directory] = nodes
            bases[directory] = tip
            let commit = nodes.map(Fixture.commit).joined(separator: "+")
            heads[directory] = commit
            return LandingBatchWorkspace(
                directory: directory, branch: "agentos/GH-161-REQ", baseCommit: tipCommit,
                candidateCommit: commit, members: nodes.map {
                    LandingBatchMember(node: $0, commit: Fixture.commit($0), changedFiles: ["Sources/\($0).swift"])
                }
            )
        }

        func landBatch(_ batch: LandingBatchWorkspace) async throws -> LandingBatchMove {
            guard batch.baseCommit == tipCommit else { return .branchMoved }
            let nodes = batch.members.map(\.node)
            try #require(try self.nodes(in: batch.directory) == nodes)
            try #require(bases[batch.directory] == tip)
            tip += nodes
            tipCommit = batch.candidateCommit
            landings.append(nodes)
            return .landed
        }

        func prepare() async throws {}
        func catchUpRequirementBranch(for requirement: NodeIdentity) async throws -> String { tipCommit }
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: "leaves/\(id)") }
        func createWorktree(for id: NodeID) async throws -> URL { worktree(for: id) }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            try await head(of: directory)
        }
        func head(of directory: URL) async throws -> String {
            try #require(heads[directory], "The fixture needs a seeded commit")
        }
        func changedFiles(in directory: URL) async throws -> [String] {
            try nodes(in: directory).map { "Sources/\($0).swift" }
        }
        nonisolated var testArea: String { "Tests/" }
        nonisolated func testFolder(for spec: NodeSpec) -> String { testArea + spec.testTarget }
        nonisolated var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            _ = try nodes(in: directory)
            bases[directory] = tip
            return .clean
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String {
            try #require(bases[worktree(for: id)] == tip)
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
            candidates[directory] = []
            bases[directory] = tip
            heads[directory] = tipCommit
            return directory
        }
        func removeSnapshot(_ directory: URL) async {}
    }
}
