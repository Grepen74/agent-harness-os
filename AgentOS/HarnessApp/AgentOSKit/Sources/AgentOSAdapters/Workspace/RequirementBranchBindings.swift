import AgentOSCore
import Synchronization

/// Ephemeral workspace bindings, restored from the ledger before operating on leaves.
public final class RequirementBranchBindings: Sendable {
    private let branches = Mutex<[NodeID: String]>([:])

    public init() {}

    public func bind(_ leaves: [NodeID], to branch: String) {
        branches.withLock { bindings in
            for id in leaves { bindings[id] = branch }
        }
    }

    public func branch(for id: NodeID) throws -> String {
        guard let branch = branches.withLock({ $0[id] }) else {
            throw AgentFailure("Missing requirement binding for \(id). Restore requirement branches before using leaves.")
        }
        return branch
    }
}
