import AgentOSCore
import Foundation

/// A tracker as people use it through the app: tickets to list, label, comment on, create and edit. The
/// harness itself only sees it through `adapter`.
public protocol TicketBoard: Sendable {
    /// For people, e.g. "Local tracker" or "GitHub Issues: owner/name".
    var name: String { get }
    /// What the reconciler reads signals from and writes back to.
    var adapter: any TrackerAdapter { get }

    func tickets() async -> [Ticket]
    func addLabel(_ name: String, to key: String, by who: Participant) async
    func removeLabel(_ name: String, from key: String) async
    func addComment(_ text: String, to key: String, by who: Participant) async
    /// Nil when the tracker refused it (see `takeProblems`).
    func newTicket(title: String, description: String, acceptanceCriteria: [String], blockedBy: [String],
                   by author: Participant) async -> Ticket?
    func edit(_ key: String, title: String, description: String, acceptanceCriteria: [String], blockedBy: [String]) async
    /// What went wrong talking to the tracker since the last call, for the activity log.
    func takeProblems() async -> [String]
}

extension LocalTracker: TicketBoard {
    public nonisolated var name: String { "Local tracker" }
    public nonisolated var adapter: any TrackerAdapter { LocalTrackerAdapter(tracker: self) }

    public func newTicket(title: String, description: String, acceptanceCriteria: [String], blockedBy: [String],
                          by author: Participant) -> Ticket? {
        createTicket(title: title, description: description, acceptanceCriteria: acceptanceCriteria, blockedBy: blockedBy, by: author)
    }

    public func takeProblems() -> [String] { [] }
}
