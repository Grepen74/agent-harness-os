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
    /// Throws when the tracker refuses; the reconciler escalates and creates the rest on retry.
    func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String
    func comment(on key: String, _ text: String) async
    func setStatus(of key: String, to status: String) async
    /// A ticket the harness made that's no longer wanted (its parent was replanned): say why, and close it.
    func close(_ key: String, saying text: String) async
}

extension TrackerAdapter {
    /// Trackers without closing show it as a status.
    public func close(_ key: String, saying text: String) async {
        await comment(on: key, text)
        await setStatus(of: key, to: "Superseded")
    }
}

extension NodeSpec {
    /// The node's identity as shown on its ticket. Child tickets carry it in the description (the
    /// harness wrote them); adopted tickets get it in a comment, since their description is the human's.
    public var trackerSummary: String {
        "Work node: \(id) · kind: \(kind.rawValue)" + (touches.isEmpty ? "" : " · touches: " + touches.joined(separator: ", "))
    }
}
