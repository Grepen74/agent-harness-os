import Foundation

/// A request found on a ticket: a `harness:` label.
public struct Signal: Sendable {
    public let ticket: String
    public let command: HarnessCommand
    public let setBy: Participant
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

/// Translates between the harness and the mock tracker.
/// Production: one adapter per tool (Jira, GitHub Issues, Azure DevOps, Polarion…), using webhooks
/// plus regular polling, with retries and rate limits.
public struct MockTrackerAdapter: TrackerAdapter {
    let tracker: MockTracker

    public init(tracker: MockTracker) { self.tracker = tracker }

    public func pendingSignals() async -> [Signal] {
        await tracker.tickets().flatMap { ticket in
            ticket.labels.compactMap { mark in
                HarnessCommand.allCases.first { $0.label == mark.name }
                    .map { Signal(ticket: ticket.key, command: $0, setBy: mark.setBy) }
            }
        }
    }

    public func ticket(_ key: String) async -> Ticket? { await tracker.ticket(key) }

    public func consume(_ signal: Signal, reply: String) async {
        await tracker.removeLabel(signal.command.label, from: signal.ticket)
        await tracker.addComment(reply, to: signal.ticket, by: .reconciler)
    }

    public func createChildTicket(parent: String, spec: NodeSpec, by who: Participant) async -> String {
        let description = """
        \(spec.intent)

        Work node: \(spec.id) · kind: \(spec.kind.rawValue)\(spec.touches.isEmpty ? "" : " · touches: " + spec.touches.joined(separator: ", "))
        """
        return await tracker.createTicket(
            title: spec.title, description: description, acceptanceCriteria: spec.acceptanceCriteria,
            blockedBy: spec.dependsOn, parentKey: parent, by: who
        ).key
    }

    public func comment(on key: String, _ text: String) async {
        await tracker.addComment(text, to: key, by: .reconciler)
    }

    public func setStatus(of key: String, to status: String) async {
        await tracker.setStatus(status, of: key)
    }
}
