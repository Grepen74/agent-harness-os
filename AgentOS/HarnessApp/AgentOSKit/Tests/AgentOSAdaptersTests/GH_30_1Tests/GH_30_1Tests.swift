// API contract: AgentContextBuilder builds a bounded, read-only AgentContext from ticket snapshots.
// AgentTask and BreakdownRequest accept agentContext; all Copilot roles render it as data and log its inventory.

import AgentOSCore
import AgentOSAdapters
import Foundation
import Testing

@Suite
struct GH_30_1Tests {
    @Test
    func humanCommentsAreChronologicalAndOnlyTheNewestThirtyAreSupplied() {
        var current = ticket("GH-1")
        let humans = (1...35).map { comment("human-\($0)", at: $0) }
        current.comments = Array(humans.reversed()) + [
            comment("reconciler-secret", at: 100, author: .reconciler),
            comment("agent-secret", at: 101, author: .agent(run: "r", role: .testAuthor)),
            comment("adapter-secret", at: 102, author: .adapter("tracker")),
        ]
        let original = current

        let context = build(current)

        #expect(context.ticketComments.map(\.text) == (6...35).map { "human-\($0)" })
        #expect(context.ticketComments.allSatisfy { $0.author.isHuman })
        #expect(context.ticketCommentsOmitted)
        #expect(current == original)
    }

    @Test
    func characterBudgetRetainsTheNewestTwentyThousandCharacters() {
        var current = ticket("GH-1")
        current.comments = [
            comment("OLD-PREFIX" + String(repeating: "a", count: 12_000), at: 1),
            comment(String(repeating: "b", count: 12_000), at: 2),
        ]

        let context = build(current)

        #expect(context.ticketComments.map(\.text).joined()
            == String(repeating: "a", count: 8_000) + String(repeating: "b", count: 12_000))
        #expect(context.ticketComments.reduce(0) { $0 + $1.text.count } == 20_000)
        #expect(context.ticketCommentsOmitted)
    }

    @Test
    func exactlyThirtyCommentsAndTwentyThousandCharactersNeedNoOmissionNotice() {
        var current = ticket("GH-1")
        current.comments = (1...29).map { comment("x", at: $0) }
            + [comment(String(repeating: "y", count: 19_971), at: 30)]

        let context = build(current)

        #expect(context.ticketComments == current.comments)
        #expect(!context.ticketCommentsOmitted)
        #expect(!build(ticket("GH-2")).ticketCommentsOmitted)
    }

    @Test
    func allReferenceFormsAreDeduplicatedInFirstMentionedOrderWithoutForeignURLs() {
        var current = ticket("GH-1", description: """
            First #8, then GH-3, then https://github.com/acme/widget/issues/9.
            Repeated GH-8 and https://github.com/acme/widget/issues/3 must not duplicate records.
            Foreign https://github.com/other/widget/issues/77 is not this repository.
            """)
        current.acceptanceCriteria = ["Reuse GH-4 and #5"]
        current.comments = [
            comment("Then #6 and GH-7", at: 1),
            comment("Ignore #88", at: 2, author: .reconciler),
        ]
        current.blockedBy = ["GH-10", "GH-8", "BACKEND-99"]
        let related = [8, 3, 9, 4, 5, 6, 7, 10, 77, 88].map { ticket("GH-\($0)") }
            + [ticket("BACKEND-99")]

        let context = build(current, related: related)

        #expect(context.linkedIssues.map(\.key) == [
            "GH-8", "GH-3", "GH-9", "GH-4", "GH-5", "GH-6", "GH-7", "GH-10",
        ])
    }

    @Test
    func linkedIssuesAreCappedAtTenInMentionOrderRatherThanSnapshotOrder() {
        let order = [12, 4, 8, 2, 9, 3, 11, 6, 5, 10, 7, 13]
        let current = ticket("GH-1", description: order.map { "#\($0)" }.joined(separator: " "))

        let context = build(current, related: (2...13).map { ticket("GH-\($0)") })

        #expect(context.linkedIssues.map(\.key) == order.prefix(10).map { "GH-\($0)" })
    }

    @Test
    func linkedRecordsCarryIssueDetailsAndOpenOrClosedStateButDoNotExpandReferences() async throws {
        let current = ticket("GH-1", description: "See #2 and GH-3")
        var open = ticket("GH-2", title: "DEPENDENCY-ALPHA", description: "Linked description; see #4")
        open.acceptanceCriteria = ["Linked acceptance criterion"]
        open.status = "Open"
        open.comments = [comment("LINKED-COMMENT-SECRET", at: 1)]
        open.blockedBy = ["GH-5"]
        var closed = ticket("GH-3", title: "DEPENDENCY-BETA")
        closed.status = "Closed"
        let context = build(current, related: [
            open, closed,
            ticket("GH-4", title: "RECURSIVE-REFERENCE-SECRET"),
            ticket("GH-5", title: "RECURSIVE-BLOCKER-SECRET"),
        ])

        #expect(context.linkedIssues.map(\.key) == ["GH-2", "GH-3"])
        let first = try #require(context.linkedIssues.first)
        #expect(first.title == open.title)
        #expect(first.description == open.description)
        #expect(first.acceptanceCriteria == open.acceptanceCriteria)
        #expect(first.isOpen)
        #expect(context.linkedIssues.last?.isOpen == false)
        for role in AgentModels.roles {
            let output = try await capture(role, ticket: current, context: context)
            #expect(output.prompt.contains(open.title))
            #expect(output.prompt.contains(open.description))
            #expect(output.prompt.contains("Linked acceptance criterion"))
            #expect(output.prompt.contains(closed.title))
            let openBlock = try #require(dataBlock(around: open.title, in: output.prompt))
            let closedBlock = try #require(dataBlock(around: closed.title, in: output.prompt))
            #expect(openBlock.localizedCaseInsensitiveContains("open"))
            #expect(closedBlock.localizedCaseInsensitiveContains("closed"))
            #expect(!output.prompt.contains("LINKED-COMMENT-SECRET"))
            #expect(!output.prompt.contains("RECURSIVE-REFERENCE-SECRET"))
            #expect(!output.prompt.contains("RECURSIVE-BLOCKER-SECRET"))
        }
    }

    @Test
    func parentContextContainsItsDetailsBoundedHumanCommentsAndOnlySiblingTitles() {
        let fixture = family()

        let context = build(fixture.child, related: fixture.related)

        let parent = context.parent
        #expect(parent?.key == "GH-20")
        #expect(parent?.title == "PARENT-TITLE")
        #expect(parent?.description == "PARENT-DESCRIPTION")
        #expect(parent?.acceptanceCriteria == ["PARENT-AC"])
        #expect(parent?.comments.map(\.text) == ["PARENT-HUMAN-ONE", "PARENT-HUMAN-TWO"])
        #expect(parent?.commentsOmitted == false)
        #expect(Set(parent?.siblingTitles ?? []) == ["SIBLING-ONE", "SIBLING-TWO"])
    }

    @Test
    func parentCommentLimitsAreIndependentOfTheCurrentTicketLimits() throws {
        var fixture = family()
        var parent = fixture.related.removeFirst()
        parent.comments = (1...35).map { comment("parent-\($0)", at: $0) }
        fixture.related.insert(parent, at: 0)
        let countBounded = try #require(build(fixture.child, related: fixture.related).parent)
        #expect(countBounded.comments.map(\.text) == (6...35).map { "parent-\($0)" })
        #expect(countBounded.commentsOmitted)

        parent.comments = [
            comment(String(repeating: "p", count: 12_000), at: 1),
            comment(String(repeating: "q", count: 12_000), at: 2),
        ]
        fixture.related[0] = parent
        let context = build(fixture.child, related: fixture.related)
        let characterBounded = try #require(context.parent)
        #expect(characterBounded.comments.map(\.text).joined()
            == String(repeating: "p", count: 8_000) + String(repeating: "q", count: 12_000))
        #expect(characterBounded.commentsOmitted)
        #expect(context.ticketComments.map(\.text) == ["TICKET-HUMAN-ONE", "TICKET-HUMAN-TWO"])
        #expect(!context.ticketCommentsOmitted)
    }

    @Test
    func decomposerAndTestAuthorReceiveTicketAndParentCommentsInTheirPrompts() async throws {
        let fixture = family()
        let context = build(fixture.child, related: fixture.related)

        for role in [AgentRole.decomposer, .testAuthor] {
            let output = try await capture(role, ticket: fixture.child, context: context)
            for text in ["TICKET-HUMAN-ONE", "TICKET-HUMAN-TWO", "PARENT-HUMAN-ONE", "PARENT-HUMAN-TWO"] {
                #expect(output.prompt.contains(text))
            }
            expectBefore("TICKET-HUMAN-ONE", "TICKET-HUMAN-TWO", in: output.prompt)
            expectBefore("PARENT-HUMAN-ONE", "PARENT-HUMAN-TWO", in: output.prompt)
            expectFamilyDetails(in: output.prompt)
            #expect(!output.prompt.contains("TICKET-HARNESS-SECRET"))
            #expect(!output.prompt.contains("PARENT-HARNESS-SECRET"))
        }
    }

    @Test
    func implementerReceivesRelationshipsAndSiblingTitlesWithoutAnyComments() async throws {
        let fixture = family()
        let output = try await capture(
            .implementer, ticket: fixture.child,
            context: build(fixture.child, related: fixture.related)
        )

        expectFamilyDetails(in: output.prompt)
        for text in [
            "TICKET-HUMAN-ONE", "TICKET-HUMAN-TWO", "TICKET-HARNESS-SECRET",
            "PARENT-HUMAN-ONE", "PARENT-HUMAN-TWO", "PARENT-HARNESS-SECRET",
            "LINKED-COMMENT-SECRET", "SIBLING-DESCRIPTION-SECRET", "UNRELATED-TITLE-SECRET",
        ] {
            #expect(!output.prompt.contains(text))
        }
    }

    @Test
    func suppliedTextIsInsideExplicitDataNotInstructionBlocksForEveryRole() async throws {
        let fixture = family()
        let context = build(fixture.child, related: fixture.related)

        for role in AgentModels.roles {
            let output = try await capture(role, ticket: fixture.child, context: context)
            var payloads = [
                "TICKET-TITLE", "TICKET-DESCRIPTION", "TICKET-AC",
                "LINKED-TITLE", "LINKED-DESCRIPTION", "LINKED-AC",
                "PARENT-TITLE", "PARENT-DESCRIPTION", "PARENT-AC", "SIBLING-ONE",
            ]
            if role != .implementer {
                payloads += ["TICKET-HUMAN-ONE", "PARENT-HUMAN-ONE"]
            }
            for payload in payloads {
                expectDataBlock(around: payload, in: output.prompt)
            }
        }
    }

    @Test
    func promptsTellReadersWhenTicketOrParentCommentsWereOmitted() async throws {
        var fixture = family()
        fixture.child.comments = (1...31).map { comment("ticket-visible-\($0)", at: $0) }
        fixture.related[0].comments = (1...31).map { comment("parent-visible-\($0)", at: $0) }
        let context = build(fixture.child, related: fixture.related)

        for role in [AgentRole.decomposer, .testAuthor] {
            let output = try await capture(role, ticket: fixture.child, context: context)
            for payload in ["ticket-visible-2", "parent-visible-2"] {
                let block = try #require(dataBlock(around: payload, in: output.prompt))
                #expect(block.localizedCaseInsensitiveContains("older"))
                #expect(block.localizedCaseInsensitiveContains("omitted"))
            }
            #expect(!output.prompt.contains("ticket-visible-1\n"))
            #expect(!output.prompt.contains("parent-visible-1\n"))
        }
    }

    @Test
    func everyRoleLogBeginsWithTheContextActuallySuppliedBeforeCLIOutput() async throws {
        let fixture = family()
        let documents = ["docs/architecture.md", "docs/decisions/storage.md"]
        let context = build(fixture.child, related: fixture.related, documents: documents)

        for role in AgentModels.roles {
            let output = try await capture(role, ticket: fixture.child, context: context)
            let marker = try #require(output.log.range(of: "CLI_OUTPUT_BEGIN"))
            let prefix = String(output.log[..<marker.lowerBound])
            let count = role == .implementer ? 0 : 4
            let pattern = #"(?i)(comments?[^0-9\n]*\#(count)\b|\b\#(count)[^0-9\n]*comments?)"#
            #expect(prefix.range(of: pattern, options: .regularExpression) != nil)
            #expect(prefix.contains("GH-2"))
            #expect(prefix.contains("GH-20"))
            for document in documents {
                #expect(prefix.contains(document))
                #expect(output.prompt.contains(document))
            }
            #expect(!prefix.contains("TICKET-HUMAN-ONE"))
            #expect(!prefix.contains("PARENT-HUMAN-ONE"))
        }
    }

    @Test
    func emptyContextIsLoggedWithZeroCommentsAndDoesNotInventRelationships() async throws {
        let current = ticket("GH-1")
        let context = build(current)
        #expect(context.ticketComments.isEmpty)
        #expect(context.linkedIssues.isEmpty)
        #expect(context.parent == nil)

        for role in AgentModels.roles {
            let output = try await capture(role, ticket: current, context: context)
            let marker = try #require(output.log.range(of: "CLI_OUTPUT_BEGIN"))
            let prefix = String(output.log[..<marker.lowerBound])
            #expect(prefix.range(
                of: #"(?i)(comments?[^0-9\n]*0\b|\b0[^0-9\n]*comments?)"#,
                options: .regularExpression
            ) != nil)
            #expect(!output.prompt.contains("PARENT-TITLE"))
            #expect(!output.prompt.contains("LINKED-TITLE"))
        }
    }

    private func build(
        _ current: Ticket, related: [Ticket] = [], documents: [String] = []
    ) -> AgentContext {
        AgentContextBuilder.build(
            ticket: current, tickets: related, repository: "acme/widget",
            designDocumentPaths: documents
        )
    }

    private func ticket(
        _ key: String, title: String = "Issue title", description: String = "Issue description"
    ) -> Ticket {
        Ticket(
            key: key, title: title, description: description,
            acceptanceCriteria: ["Issue acceptance criterion"], createdBy: .human("author")
        )
    }

    private func comment(
        _ text: String, at seconds: Int, author: Participant = .human("reader")
    ) -> AgentOSCore.Comment {
        var result = AgentOSCore.Comment(author: author, text: text)
        result.at = Date(timeIntervalSince1970: TimeInterval(seconds))
        return result
    }

    private func family() -> (child: Ticket, related: [Ticket]) {
        var child = ticket("GH-1", title: "TICKET-TITLE", description: "TICKET-DESCRIPTION; see #2")
        child.acceptanceCriteria = ["TICKET-AC"]
        child.parentKey = "GH-20"
        child.comments = [
            comment("TICKET-HUMAN-TWO", at: 2),
            comment("TICKET-HARNESS-SECRET", at: 3, author: .reconciler),
            comment("TICKET-HUMAN-ONE", at: 1),
        ]
        var parent = ticket("GH-20", title: "PARENT-TITLE", description: "PARENT-DESCRIPTION")
        parent.acceptanceCriteria = ["PARENT-AC"]
        parent.comments = [
            comment("PARENT-HUMAN-TWO", at: 2),
            comment("PARENT-HARNESS-SECRET", at: 3, author: .agent(run: "r", role: .decomposer)),
            comment("PARENT-HUMAN-ONE", at: 1),
        ]
        var firstSibling = ticket("GH-21", title: "SIBLING-ONE", description: "SIBLING-DESCRIPTION-SECRET")
        firstSibling.parentKey = parent.key
        var secondSibling = ticket("GH-22", title: "SIBLING-TWO")
        secondSibling.parentKey = parent.key
        var linked = ticket("GH-2", title: "LINKED-TITLE", description: "LINKED-DESCRIPTION")
        linked.acceptanceCriteria = ["LINKED-AC"]
        linked.comments = [comment("LINKED-COMMENT-SECRET", at: 1)]
        return (child, [
            parent, secondSibling, child, firstSibling, linked,
            ticket("GH-99", title: "UNRELATED-TITLE-SECRET"),
        ])
    }

    private func expectFamilyDetails(in prompt: String) {
        for text in [
            "PARENT-TITLE", "PARENT-DESCRIPTION", "PARENT-AC", "SIBLING-ONE", "SIBLING-TWO",
            "LINKED-TITLE", "LINKED-DESCRIPTION", "LINKED-AC",
        ] {
            #expect(prompt.contains(text))
        }
    }

    private func expectBefore(_ first: String, _ second: String, in text: String) {
        let firstRange = text.range(of: first)
        let secondRange = text.range(of: second)
        #expect(firstRange != nil)
        #expect(secondRange != nil)
        if let firstRange, let secondRange {
            #expect(firstRange.lowerBound < secondRange.lowerBound)
        }
    }

    private func dataBlock(around payload: String, in prompt: String) -> String? {
        var header: String?
        var lines: [String] = []
        for line in prompt.components(separatedBy: "\n") {
            if line.hasPrefix("<<<") {
                header = line
                lines = [line]
            } else if header != nil {
                lines.append(line)
                if line.hasSuffix(">>>") {
                    let block = lines.joined(separator: "\n")
                    if block.contains(payload) { return block }
                    header = nil
                    lines = []
                }
            }
        }
        return nil
    }

    private func expectDataBlock(around payload: String, in prompt: String) {
        let block = dataBlock(around: payload, in: prompt)
        #expect(block != nil, "Missing marked data block for \(payload)")
        if let block {
            let header = block.components(separatedBy: "\n")[0]
            #expect(header.localizedCaseInsensitiveContains("data"))
            #expect(header.localizedCaseInsensitiveContains("not instructions"))
        }
    }

    private func capture(
        _ role: AgentRole, ticket: Ticket, context: AgentContext
    ) async throws -> (prompt: String, log: String) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agentos-gh-30-1-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "fake-copilot")
        try """
            #!/bin/sh
            test "$1" = "-p" || exit 2
            printf '%s' "$2" > "$(dirname "$0")/captured-prompt.txt"
            printf '%s\\n' 'CLI_OUTPUT_BEGIN'
            printf '%s\\n' '{"questions":["fixture question"],"children":[]}'
            """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let log = root.appending(path: "agent.log")
        let spec = NodeSpec(
            id: "wn-\(ticket.key)", parent: ticket.parentKey.map { "wn-\($0)" }, kind: .leaf,
            title: ticket.title, intent: ticket.description, acceptanceCriteria: ticket.acceptanceCriteria
        )
        let team = AgentTeam.copilot(CopilotCLI(executable: executable.path, timeout: .seconds(10)))
        let task = AgentTask(
            spec: spec, run: "fixture-run", directory: root, testFolder: "Tests/FixtureTests",
            scratchDirectory: root.appending(path: "scratch"), log: log, agentContext: context
        )
        switch role {
        case .decomposer:
            _ = try await team.decomposer.proposeChildren(BreakdownRequest(
                spec: spec, log: log, codebase: root, agentContext: context
            ))
        case .testAuthor:
            _ = try await team.testAuthor.writeAcceptanceTests(task)
        case .implementer:
            _ = try await team.implementer.implement(task)
        case .verifier:
            throw AgentFailure("The verifier is not a Copilot agent role")
        }
        return (
            try String(contentsOf: root.appending(path: "captured-prompt.txt"), encoding: .utf8),
            try String(contentsOf: log, encoding: .utf8)
        )
    }
}
