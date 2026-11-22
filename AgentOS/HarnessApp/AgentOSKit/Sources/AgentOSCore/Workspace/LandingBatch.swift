import Foundation

/// A batch candidate with its ledger identity, shared throughout checking and diagnosis.
struct LandingBatch: Sendable {
    let id: String
    let branch: String
    let directory: URL
    let candidateCommit: String
    let members: [LandingBatchMember]

    init(id: String, workspace: LandingBatchWorkspace) {
        self.id = id
        self.branch = workspace.branch
        self.directory = workspace.directory
        self.candidateCommit = workspace.candidateCommit
        self.members = workspace.members
    }
}
