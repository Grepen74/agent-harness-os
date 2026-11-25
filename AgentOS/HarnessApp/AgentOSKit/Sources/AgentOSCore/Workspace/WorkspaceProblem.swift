import Foundation

/// The machine or a working copy failed, not the work: a git command that ran out of time on a busy machine, say, or
/// a leaf's working copy that couldn't be set up. Trying again later may fix it by itself, so a run that ends on one
/// isn't a failed attempt and doesn't use up the ticket's run budget.
public struct WorkspaceProblem: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }

    static let outcomePrefix = "workspace problem: "
    /// How a run that ended on it is recorded.
    var outcome: String { Self.outcomePrefix + description }
    static func isOutcome(_ outcome: String) -> Bool { outcome.hasPrefix(outcomePrefix) }
}
