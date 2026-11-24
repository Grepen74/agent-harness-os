import Foundation

extension Reconciler {
    /// Observe without reacting on the tracker. The ledger deduplicates by ticket and comment ID.
    func observeIgnoredComments(signals: [Signal]) async throws {
        let state = await ledger.workingState()
        var keys = Set(state.nodes.values.filter { !$0.ticketClosed }.map(\.ticket))
        keys.formUnion(signals.map(\.ticket))
        for key in keys.sorted() {
            guard let ticket = await tracker.ticket(key) else { continue }
            let events = ticket.comments.filter { $0.writeAccess == .denied }.map { comment in
                LedgerEvent(node: nil, by: .reconciler, kind: .commentIgnored(
                    ticket: ticket.key, commentID: comment.id, author: comment.author), at: now())
            }
            try await ledger.append(events)
        }
    }
}
