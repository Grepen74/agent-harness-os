import Foundation

/// A request found on a ticket: a `harness:` label.
public struct Signal: Sendable {
    public let ticket: String
    public let command: HarnessCommand
    public let setBy: Participant

    public init(ticket: String, command: HarnessCommand, setBy: Participant) {
        self.ticket = ticket
        self.command = command
        self.setBy = setBy
    }
}

/// What the harness needs from any tracker (doc 03). Adapters only translate; they never decide.
public protocol TrackerAdapter: Sendable {
    func pendingSignals() async -> [Signal]
    func ticket(_ key: String) async -> Ticket?
    /// Labels are one-time requests: remove the label and reply, so the ticket shows what happened.
    func consume(_ signal: Signal, reply: String) async
    func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async -> String
    func comment(on key: String, _ text: String) async
    func setStatus(of key: String, to status: String) async
}

extension NodeSpec {
    /// The node's identity as shown on its ticket. Child tickets carry it in the description (the
    /// harness wrote them); adopted tickets get it in a comment, since their description is the human's.
    public var trackerSummary: String {
        "Work node: \(id) · kind: \(kind.rawValue)" + (touches.isEmpty ? "" : " · touches: " + touches.joined(separator: ", "))
    }
}
