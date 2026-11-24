import Foundation

/// A tracker's accepted issue body and any later edit awaiting a trusted person's confirmation.
public struct TicketDescription: Codable, Sendable, Equatable {
    public let body: String
    public let acceptedAt: Date?
    public let heldEditor: String?

    public init(body: String, acceptedAt: Date?, heldEditor: String? = nil) {
        self.body = body
        self.acceptedAt = acceptedAt
        self.heldEditor = heldEditor
    }

    public func attentionReason(ticket: String) -> String? {
        heldEditor.map {
            "\(ticket): description edited by \($0), who doesn't have write access; the harness keeps building "
                + "from the description it accepted. A person with write access must confirm: edit the description, "
                + "or add harness:replan."
        }
    }
}
