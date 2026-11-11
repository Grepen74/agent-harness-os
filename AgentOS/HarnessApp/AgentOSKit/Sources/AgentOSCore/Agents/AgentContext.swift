import Foundation

public struct LinkedIssueContext: Sendable {
    public let key: String
    public let title: String
    public let isOpen: Bool
    public let description: String
    public let acceptanceCriteria: [String]
}

public struct ParentIssueContext: Sendable {
    public let key: String
    public let title: String
    public let description: String
    public let acceptanceCriteria: [String]
    public let comments: [Comment]
    public let commentsOmitted: Bool
    public let siblingTitles: [String]
}

/// A bounded snapshot of ticket relationships, never agent instructions.
public struct AgentContext: Sendable {
    public let ticketComments: [Comment]
    public let ticketCommentsOmitted: Bool
    public let linkedIssues: [LinkedIssueContext]
    public let parent: ParentIssueContext?
    public let designDocumentPaths: [String]

    public init(ticketComments: [Comment] = [], ticketCommentsOmitted: Bool = false,
                linkedIssues: [LinkedIssueContext] = [], parent: ParentIssueContext? = nil,
                designDocumentPaths: [String] = []) {
        self.ticketComments = ticketComments
        self.ticketCommentsOmitted = ticketCommentsOmitted
        self.linkedIssues = linkedIssues
        self.parent = parent
        self.designDocumentPaths = designDocumentPaths
    }

    public func withoutComments() -> AgentContext {
        let parent = parent.map {
            ParentIssueContext(key: $0.key, title: $0.title, description: $0.description,
                               acceptanceCriteria: $0.acceptanceCriteria, comments: [],
                               commentsOmitted: false, siblingTitles: $0.siblingTitles)
        }
        return AgentContext(linkedIssues: linkedIssues, parent: parent, designDocumentPaths: designDocumentPaths)
    }
}

public enum AgentContextBuilder {
    public static func build(ticket: Ticket, tickets: [Ticket], repository: String,
                             designDocumentPaths: [String]) -> AgentContext {
        let comments = boundedComments(ticket.comments)
        let linked = referencedKeys(in: ticket, repository: repository).compactMap { key -> LinkedIssueContext? in
            guard let issue = tickets.first(where: { $0.key == key }) else { return nil }
            return LinkedIssueContext(
                key: key, title: issue.title,
                isOpen: !["closed", "done", "superseded"].contains(issue.status.lowercased()),
                description: issue.description, acceptanceCriteria: issue.acceptanceCriteria
            )
        }.prefix(10)
        let parent = tickets.first(where: { $0.key == ticket.parentKey }).map { issue in
            let comments = boundedComments(issue.comments)
            return ParentIssueContext(
                key: issue.key, title: issue.title, description: issue.description,
                acceptanceCriteria: issue.acceptanceCriteria, comments: comments.values,
                commentsOmitted: comments.omitted,
                siblingTitles: tickets.filter { $0.parentKey == issue.key && $0.key != ticket.key }.map(\.title)
            )
        }
        return AgentContext(ticketComments: comments.values, ticketCommentsOmitted: comments.omitted,
                            linkedIssues: Array(linked), parent: parent, designDocumentPaths: designDocumentPaths)
    }

    /// Also used by trackers to fetch only the directly referenced issues missing from their snapshot.
    public static func referencedKeys(in ticket: Ticket, repository: String) -> [String] {
        let humans = ticket.comments.filter { $0.author.isHuman }.sorted { $0.at < $1.at }
        let text = ([ticket.description] + ticket.acceptanceCriteria + humans.map(\.text)).joined(separator: "\n")
        // Consume whole URLs first so foreign URLs cannot contribute shorthand references.
        let pattern = #"https?://[^\s<>]+|(?<![\w/#-])(?:GH-|#)([0-9]+)\b"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var keys: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let value = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}\"'"))
            if let numberRange = Range(match.range(at: 1), in: text) {
                keys.append("GH-\(text[numberRange])")
            } else if let url = URL(string: value), url.host?.lowercased() == "github.com" {
                let parts = url.path.split(separator: "/")
                if parts.count == 4, "\(parts[0])/\(parts[1])".lowercased() == repository.lowercased(),
                   parts[2] == "issues", Int(parts[3]) != nil {
                    keys.append("GH-\(parts[3])")
                }
            }
        }
        let trackerPrefix = ticket.key.prefix { !$0.isNumber }
        keys += ticket.blockedBy.filter { $0.hasPrefix(trackerPrefix) }
        var seen: Set<String> = [ticket.key]
        return keys.filter { seen.insert($0).inserted }
    }

    private static func boundedComments(_ comments: [Comment]) -> (values: [Comment], omitted: Bool) {
        let humans = comments.enumerated().filter { $0.element.author.isHuman }.sorted {
            $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at
        }.map(\.element)
        var omitted = humans.count > 30
        var remaining = 20_000
        var result: [Comment] = []
        for comment in humans.suffix(30).reversed() {
            guard remaining > 0 else {
                omitted = true
                continue
            }
            let text = String(comment.text.suffix(remaining))
            remaining -= text.count
            if text == comment.text {
                result.append(comment)
            } else {
                var truncated = Comment(author: comment.author, text: text)
                truncated.id = comment.id
                truncated.at = comment.at
                result.append(truncated)
                omitted = true
            }
        }
        return (Array(result.reversed()), omitted)
    }
}
