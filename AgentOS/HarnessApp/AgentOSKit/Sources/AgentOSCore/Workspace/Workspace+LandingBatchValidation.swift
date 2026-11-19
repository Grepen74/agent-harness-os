import Foundation

public typealias LandingBatchValidation = @Sendable (LandingBatchWorkspace, LandingBatchMember) async throws -> Void

public extension Workspace {
    /// Compatibility for workspaces that only build whole candidates. Real adapters can validate in place.
    func createLandingBatch(for nodes: [NodeID], validating: @escaping LandingBatchValidation) async throws -> LandingBatchWorkspace {
        guard !nodes.isEmpty else { throw AgentFailure("A landing batch needs at least one node.") }
        var candidate: LandingBatchWorkspace?
        do {
            for index in nodes.indices {
                if let previous = candidate {
                    await removeSnapshot(previous.directory)
                    candidate = nil
                }
                let batch = try await createLandingBatch(for: Array(nodes[...index]))
                candidate = batch
                guard let member = batch.members.last, member.node == nodes[index] else {
                    throw AgentFailure("The landing batch did not include \(nodes[index]).")
                }
                try await validating(batch, member)
            }
            guard let candidate else { throw AgentFailure("The landing batch has no candidate.") }
            return candidate
        } catch {
            if let candidate { await removeSnapshot(candidate.directory) }
            throw error
        }
    }
}
