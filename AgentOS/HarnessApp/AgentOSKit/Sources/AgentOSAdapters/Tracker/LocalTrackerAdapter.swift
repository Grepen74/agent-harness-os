import AgentOSCore
import Foundation

/// Translates between the harness and the local tracker.
/// Production: one adapter per tool (Jira, GitHub Issues, Azure DevOps, Polarion…), using webhooks
/// plus regular polling, with retries and rate limits.
public struct LocalTrackerAdapter: TrackerAdapter {
    public let tracker: LocalTracker

    public init(tracker: LocalTracker) { self.tracker = tracker }

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

        \(spec.trackerSummary)
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
