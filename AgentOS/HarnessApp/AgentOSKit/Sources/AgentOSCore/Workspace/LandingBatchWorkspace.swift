import Foundation

public struct LandingBatchMember: Sendable {
    public let node: NodeID
    public let commit: String
    public let changedFiles: [String]

    public init(node: NodeID, commit: String, changedFiles: [String]) {
        self.node = node
        self.commit = commit
        self.changedFiles = changedFiles
    }
}

/// A disposable, detached candidate based on one exact requirement tip.
public struct LandingBatchWorkspace: Sendable {
    public let directory: URL
    public let branch: String
    public let baseCommit: String
    public let candidateCommit: String
    public let members: [LandingBatchMember]

    public init(directory: URL, branch: String, baseCommit: String, candidateCommit: String,
                members: [LandingBatchMember]) {
        self.directory = directory
        self.branch = branch
        self.baseCommit = baseCommit
        self.candidateCommit = candidateCommit
        self.members = members
    }
}

public enum LandingBatchMove: Sendable {
    case landed
    case waiting(String)
    case branchMoved
}

public struct LandingBatchConflict: Error, Sendable {
    public let node: NodeID
    public let files: [String]

    public init(node: NodeID, files: [String]) {
        self.node = node
        self.files = files
    }
}
