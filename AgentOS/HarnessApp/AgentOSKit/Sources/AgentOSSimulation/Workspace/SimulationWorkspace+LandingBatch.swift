import AgentOSAdapters
import AgentOSCore
import Foundation

extension SimulationWorkspace {
    public var supportsLandingBatches: Bool { true }

    public func createLandingBatch(for nodes: [NodeID]) async throws -> LandingBatchWorkspace {
        guard let first = nodes.first else { throw AgentFailure("A landing batch needs at least one node.") }
        let branch = try landingBranch(for: first)
        var sources: [GitLandingBatch.Source] = []
        for node in nodes {
            guard try landingBranch(for: node) == branch else {
                throw AgentFailure("A landing batch cannot mix requirement branches.")
            }
            sources.append(.init(node: node, branch: self.branch(for: node), base: branch))
        }
        let directory = try await createSnapshot(at: branch)
        do {
            return try await GitLandingBatch(root: repoDirectory).build(in: directory, branch: branch, sources: sources)
        } catch {
            await removeSnapshot(directory)
            throw error
        }
    }

    public func whyLandingMustWait(for id: NodeID) async throws -> String? {
        let branch = try landingBranch(for: id)
        let result = try await ProcessRunner.run("/usr/bin/env", ["git", "worktree", "list", "--porcelain"], in: repoDirectory)
        guard result.status == 0 else { throw AgentFailure("Could not inspect landing checkouts: \(result.output)") }
        var checkout = ""
        for line in result.output.split(separator: "\n") {
            if line.hasPrefix("worktree ") { checkout = String(line.dropFirst("worktree ".count)) }
            if line == "branch refs/heads/\(branch)" {
                return "\(branch) is checked out in \(checkout). Switch that checkout to another branch so the harness can move \(branch)"
            }
        }
        return nil
    }

    public func landBatch(_ batch: LandingBatchWorkspace) async throws -> LandingBatchMove {
        guard let first = batch.members.first, try landingBranch(for: first.node) == batch.branch else {
            throw AgentFailure("The batch's requirement branch changed. Run landing again.")
        }
        if let reason = try await whyLandingMustWait(for: first.node) { return .waiting(reason) }
        return try await GitLandingBatch(root: repoDirectory).move(batch)
    }
}
