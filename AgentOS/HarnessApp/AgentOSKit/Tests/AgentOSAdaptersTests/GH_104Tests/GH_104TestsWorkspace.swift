import AgentOSCore
import Foundation
import Testing

extension GH_104Tests {
    actor WorkspaceFake: Workspace {
        struct Tree: Sendable {
            var commit: String
            var nodes: [NodeID]
            var files: [String: String]
            var batch: Bool
        }

        nonisolated let root: URL
        let audit: Audit
        let conflicting: NodeID?
        private var trees: [URL: Tree] = [:]
        private var commits: [String: Tree] = [:]
        private var deltas: [NodeID: [String: String]] = [:]
        private var tampering: [NodeID: Tampering] = [:]
        private var rebased: Set<NodeID> = []
        private var landingTip = "requirement-tip"
        private var landingFiles: [String: String] = [:]
        private(set) var applied: [NodeID] = []
        private(set) var reworked: [NodeID] = []
        private(set) var singleLandings: [NodeID] = []
        private(set) var batchLandings: [[NodeID]] = []

        init(root: URL, audit: Audit, conflicting: NodeID?) {
            self.root = root
            self.audit = audit
            self.conflicting = conflicting
        }

        nonisolated static func otherPath(_ id: NodeID) -> String { "Tests/Existing/\(id).swift" }
        nonisolated var supportsLandingBatches: Bool { true }
        nonisolated var testArea: String { "Tests/" }
        nonisolated var updatableTestAreas: [String] { ["Tests/"] }
        nonisolated var agentContext: String { "" }
        nonisolated func branch(for id: NodeID) -> String { "agentos/leaf/\(id)" }
        nonisolated func worktree(for id: NodeID) -> URL { root.appending(path: "leaves/\(id)") }
        nonisolated func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        nonisolated func existingComponents() -> [String] { [] }

        func seed(_ spec: NodeSpec, tampering mode: Tampering?, updatesOther: Bool) throws {
            let id = spec.id
            let own = testFolder(for: spec) + "/Acceptance.swift"
            var changes = [own: "fixed acceptance tests for \(id)\n", "Sources/\(id).swift": "implementation for \(id)\n"]
            let other = Self.otherPath(id)
            landingFiles[other] = "existing proven tests\n"
            if updatesOther { changes[other] = "approved updated tests for \(id)\n" }
            deltas[id] = changes
            tampering[id] = mode
            var files = landingFiles
            files.merge(changes) { _, change in change }
            try store(Tree(commit: "candidate-\(id)", nodes: [id], files: files, batch: false), in: worktree(for: id))
        }

        func prepare() async throws {}
        func prepareRequirementBranch(for requirement: NodeIdentity, leaves: [NodeID]) async throws -> String? {
            #expect(requirement.nodeID == Fixture.parent)
            return nil
        }
        func createWorktree(for id: NodeID) async throws -> URL {
            throw AgentFailure("GH104 candidates already have working copies")
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? { nil }
        func head(of directory: URL) async throws -> String { try tree(in: directory).commit }

        func tree(in directory: URL) throws -> Tree {
            guard let tree = trees[directory] else { throw AgentFailure("Unknown GH104 tree \(directory.lastPathComponent)") }
            return tree
        }

        func nodeFiles(_ id: NodeID) -> [String] { (deltas[id] ?? [:]).keys.sorted() }

        func changedFiles(in directory: URL) async throws -> [String] {
            let tree = try tree(in: directory)
            return Array(Set(tree.nodes.flatMap { nodeFiles($0) }
                + tree.nodes.filter { tampering[$0] == .otherTests && tree.batch }.map(Self.otherPath))).sorted()
        }

        func changedFiles(in directory: URL, since commit: String) async throws -> [String] {
            let current = try tree(in: directory)
            guard let previous = commits[commit] else { throw AgentFailure("Unknown GH104 commit \(commit)") }
            return Set(current.files.keys).union(previous.files.keys).filter {
                current.files[$0] != previous.files[$0]
            }.sorted()
        }

        func reviewContext(in directory: URL, against branch: String) async throws -> ReviewContext {
            let tree = try tree(in: directory)
            return ReviewContext(baseBranch: branch, commit: tree.commit,
                                 fullDiff: tree.nodes.flatMap { nodeFiles($0) }.joined(separator: "\n"),
                                 changedFiles: try await changedFiles(in: directory),
                                 recentChanges: [], uiEvidence: nil)
        }

        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            var tree = try tree(in: directory)
            let id = try #require(tree.nodes.first)
            await audit.record("rebase:\(id)")
            if rebased.insert(id).inserted {
                tree.commit = "rebased-\(id)"
                try store(tree, in: directory)
            }
            return .clean
        }

        func rewriteCandidate(_ id: NodeID, commit: String) throws {
            var tree = try tree(in: worktree(for: id))
            tree.commit = commit
            try store(tree, in: worktree(for: id))
        }

        func tamperSingleCandidate(_ id: NodeID) throws {
            var tree = try tree(in: worktree(for: id))
            let changes = try appliedChanges(id)
            deltas[id] = changes
            tree.files.merge(changes) { _, change in change }
            try store(tree, in: worktree(for: id))
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {
            let id = try #require(tree(in: directory).nodes.first)
            reworked.append(id)
        }
        func prepareBuild(in directory: URL) async throws {}

        func landOnMain(_ id: NodeID) async throws -> String {
            let tree = try tree(in: worktree(for: id))
            singleLandings.append(id)
            landingTip = tree.commit
            landingFiles.merge(deltas[id] ?? [:]) { _, change in change }
            return tree.commit
        }

        func createLandingBatch(for nodes: [NodeID]) async throws -> LandingBatchWorkspace {
            guard !nodes.isEmpty else { throw AgentFailure("A batch needs nodes") }
            let directory = root.appending(path: "batches/\(UUID())")
            let base = landingTip
            try store(Tree(commit: base, nodes: [], files: landingFiles, batch: true), in: directory)
            await audit.record("batch:\(nodes.joined(separator: ","))")
            var members: [LandingBatchMember] = []
            for node in nodes {
                let checkpoint = try tree(in: directory).commit
                if case .conflict(let files) = try await applyToLandingBatch(node, in: directory) {
                    throw LandingBatchConflict(node: node, files: files)
                }
                members.append(LandingBatchMember(
                    node: node, commit: try tree(in: directory).commit,
                    changedFiles: try await changedFiles(in: directory, since: checkpoint)
                ))
            }
            return LandingBatchWorkspace(
                directory: directory, branch: Fixture.branch, baseCommit: base,
                candidateCommit: try tree(in: directory).commit, members: members
            )
        }

        func applyToLandingBatch(_ node: NodeID, in directory: URL) async throws -> RebaseResult {
            var tree = try tree(in: directory)
            guard tree.batch else { throw AgentFailure("Application needs a batch checkout") }
            applied.append(node)
            await audit.record("apply:\(node)")
            // Conflict is deliberately absent during the independent rebase: only the combined change conflicts.
            if node == conflicting && !tree.nodes.isEmpty { return .conflict(files: Fixture.conflictFiles) }
            let changes = try appliedChanges(node)
            tree.files.merge(changes) { _, change in change }
            tree.nodes.append(node)
            tree.commit = "batch-" + tree.nodes.joined(separator: "+")
            try store(tree, in: directory)
            return .clean
        }

        private func appliedChanges(_ node: NodeID) throws -> [String: String] {
            guard var changes = deltas[node] else { throw AgentFailure("Unknown candidate \(node)") }
            switch tampering[node] {
            case .ownTests:
                let own = try #require(changes.keys.first { $0.hasSuffix("/Acceptance.swift") })
                changes[own] = "tampered own acceptance tests\n"
            case .otherTests, .updatedOtherTests:
                changes[Self.otherPath(node)] = "tampered other tests\n"
            case nil: break
            }
            return changes
        }

        func resetLandingBatch(_ directory: URL, to commit: String) async throws {
            guard let previous = commits[commit] else { throw AgentFailure("Unknown rollback commit \(commit)") }
            try store(previous, in: directory)
        }

        func landBatch(_ batch: LandingBatchWorkspace) async throws -> LandingBatchMove {
            let tree = try tree(in: batch.directory)
            let nodes = batch.members.map(\.node)
            guard landingTip == batch.baseCommit else { return .branchMoved }
            guard tree.nodes == nodes else { throw AgentFailure("Batch still contains a removed node") }
            guard tree.commit == batch.candidateCommit else { throw AgentFailure("Batch candidate changed after checking") }
            batchLandings.append(nodes)
            landingTip = tree.commit
            landingFiles = tree.files
            return .landed
        }

        private func store(_ tree: Tree, in directory: URL) throws {
            if let old = trees[directory] {
                for path in old.files.keys where tree.files[path] == nil {
                    try FileManager.default.removeItem(at: directory.appending(path: path))
                }
            }
            for (path, contents) in tree.files {
                let file = directory.appending(path: path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: file, atomically: true, encoding: .utf8)
            }
            trees[directory] = tree
            commits[tree.commit] = tree
        }
    }
}
