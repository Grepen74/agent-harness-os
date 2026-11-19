import AgentOSCore
import Foundation

extension RepositoryWorkspace {
    public var supportsLandingBatches: Bool { true }

    public func createLandingBatch(for nodes: [NodeID]) async throws -> LandingBatchWorkspace {
        guard let first = nodes.first else { throw AgentFailure("A landing batch needs at least one node.") }
        let branch = try landingBranch(for: first)
        var sources: [GitLandingBatch.Source] = []
        for node in nodes {
            guard try landingBranch(for: node) == branch else {
                throw AgentFailure("A landing batch cannot mix requirement branches.")
            }
            let base = try await leafBase(in: worktree(for: node), landingBranch: branch)
            sources.append(.init(node: node, branch: self.branch(for: node), base: base))
        }
        let directory = try await createSnapshot(at: branch)
        do {
            return try await GitLandingBatch(root: root).build(in: directory, branch: branch, sources: sources)
        } catch {
            await removeSnapshot(directory)
            throw error
        }
    }

    public func landBatch(_ batch: LandingBatchWorkspace) async throws -> LandingBatchMove {
        try await worktreeLock.withPermit {
            guard let first = batch.members.first else { throw AgentFailure("Cannot land an empty batch.") }
            guard try landingBranch(for: first.node) == batch.branch else {
                throw AgentFailure("The batch's requirement branch changed. Run landing again.")
            }
            if let reason = try await whyLandingMustWait(for: first.node) { return .waiting(reason) }
            return try await GitLandingBatch(root: root).move(batch)
        }
    }
}
