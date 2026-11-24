// Expected API: GitHubIssuesTracker's existing ticket/context API enforces repository permissions, with
// init(..., permissionRefreshInterval: Duration, now: @Sendable () -> Date) for deterministic refresh tests.
// Existing Comment.isHumanInput, AgentContextBuilder and Reconciler consume that decision everywhere.
// Criterion 6 (real-repo-mode.md and 03-tracker-adapters.md section 8 wording) is source-only: diff review.
import AgentOSAdapters
@testable import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

@Suite struct GH_116Tests {
    @Test(arguments: ["write", "maintain", "admin"])
    func repositoryWritersReachTheDecomposerAndTestAuthorAsTicketAndParentComments(_ permission: String) async throws {
        let fixture = try await Self.githubFixture(permission: permission)
        try await fixture.say("Ticket guidance", on: "GH-2")
        try await fixture.say("Parent guidance", on: "GH-1")
        try await Self.expectContexts(fixture, containsInput: true)
    }

    @Test(arguments: ["read", "triage", "none", "bot-type", "bot-login"])
    func outsidersAndBotsNeverReachAnyAgentsTicketOrParentContext(_ access: String) async throws {
        let fixture = try await Self.githubFixture(permission: access)
        try await fixture.say("Ticket guidance", on: "GH-2")
        try await fixture.say("Parent guidance", on: "GH-1")
        try await Self.expectContexts(fixture, containsInput: false)

        let ticket = try #require(await fixture.tracker.ticket("GH-2"))
        #expect(!ticket.comments.contains { $0.text == "Ticket guidance" && $0.isHumanInput })
        let github = try #require(fixture.github)
        #expect(await github.commentBodies(on: 2).contains("Ticket guidance"),
                "Ignoring a comment must leave it on GitHub")
    }

    @Test(arguments: ["write", "maintain", "admin"], Self.inputUses)
    func repositoryWritersCanAnswerCorrectReplyToEscalationsAndGivePreviewFeedback(
        _ permission: String, _ use: String
    ) async throws {
        let fixture = try await Self.githubFixture(permission: permission)
        try await Self.exerciseInput(use, fixture: fixture, trusted: true)
    }

    @Test(arguments: ["read", "triage", "none", "bot-type", "bot-login"], Self.inputUses)
    func outsidersAndBotsCannotAnswerCorrectReplyToEscalationsOrGivePreviewFeedback(
        _ access: String, _ use: String
    ) async throws {
        let fixture = try await Self.githubFixture(permission: access)
        try await Self.exerciseInput(use, fixture: fixture, trusted: false)
    }

    @Test(arguments: Self.inputUses)
    func laterOutsiderAndBotCommentsCannotContaminateOrShadowATrustedReply(_ use: String) async throws {
        let fixture = try await Self.githubFixture(permission: "write")
        try await Self.exerciseInput(use, fixture: fixture, trusted: true, rejectingNoise: true)
    }

    @Test(arguments: ["read", "triage", "none", "bot-type", "bot-login", "no-comment"])
    func retryIsRefusedWhenThereIsNoTrustedCommentAfterTheQuestion(_ access: String) async throws {
        let fixture = try await Self.githubFixture(permission: access)
        let github = try #require(fixture.github)
        await github.setPermission("write", for: "earlier-writer")
        await github.addComment("An answer before the question", on: 2, by: "earlier-writer")
        try await fixture.seed([.questionsRaised(role: .decomposer, questions: ["Which greeting?"]),
                                .flagSet(.needsInput, reason: "Waiting for an answer")])
        try await fixture.ask("❓ Needs input\n1. Which greeting?")
        if access != "no-comment" { try await fixture.say("An unauthorized answer after the question") }

        try await fixture.signal(.retry)

        let node = try #require(await fixture.node())
        #expect(node.flags[.needsInput] != nil)
        #expect(node.openQuestions.contains(AgentQuestion(question: "Which greeting?")))
        #expect(node.clarifications.isEmpty)
        let rejected = await fixture.ledger.allRecords().contains {
            if case .signalRejected(ticket: "GH-2", command: .retry, reason: let reason) = $0.event.kind {
                return reason.contains("comment") && reason.contains("harness:retry")
            }
            return false
        }
        #expect(rejected, "An unauthorized reply must not satisfy the retry prerequisite")
    }

    @Test(arguments: ["write", "read", "triage", "none"])
    func permissionsAreCachedPerLoginAcrossTicketsReadsAndRoundsThenRefreshedEvenForUnchangedIssues(
        _ initialPermission: String
    ) async throws {
        let fixture = try await Self.githubFixture(permission: initialPermission)
        let github = try #require(fixture.github)
        await github.setPermission("maintain", for: "second-writer")
        for key in ["GH-1", "GH-2"] {
            try await fixture.say("One comment", on: key)
            try await fixture.say("Another comment", on: key)
        }
        await github.addComment("A different writer", on: 2, by: "second-writer")

        for _ in 0..<3 {
            _ = await fixture.tracker.contextTickets()
            let round = await fixture.reconciler.runRound(waitForAgents: true)
            #expect(round.safeStop == nil)
        }
        #expect(await github.permissionReads(for: fixture.login) == 1)
        #expect(await github.permissionReads(for: "second-writer") == 1)

        fixture.clock.advance(by: 299)
        try await fixture.say("A new comment within the interval")
        _ = await fixture.tracker.contextTickets()
        #expect(await github.permissionReads(for: fixture.login) == 1)
        #expect(await github.permissionReads(for: "second-writer") == 1)

        fixture.clock.advance(by: 2)
        await github.setPermission("read", for: fixture.login)
        let demoted = try #require(await fixture.tracker.ticket("GH-2"))
        #expect(!demoted.comments.contains { $0.author == .human(fixture.login) && $0.isHumanInput })
        _ = await fixture.tracker.ticket("GH-1")
        #expect(await github.permissionReads(for: fixture.login) == 2)
        #expect(await github.permissionReads(for: "second-writer") == 2)

        fixture.clock.advance(by: 301)
        await github.setPermission("admin", for: fixture.login)
        let promoted = try #require(await fixture.tracker.ticket("GH-2"))
        #expect(promoted.comments.contains { $0.text == "One comment" && $0.isHumanInput })
        #expect(await github.permissionReads(for: fixture.login) == 3)

        let otherSession = GitHubIssuesTracker(
            repo: "acme/app", transport: github, listInterval: .zero,
            permissionRefreshInterval: .seconds(300), now: { fixture.clock.now })
        _ = await otherSession.ticket("GH-2")
        #expect(await github.permissionReads(for: fixture.login) == 4,
                "A new tracker session must not reuse another session's permissions")
    }

    @Test(arguments: ["network", "HTTP 403", "HTTP 404", "HTTP 429", "HTTP 500", "malformed"])
    func failedPermissionsExcludeInputForThatReadAndAreRetriedOnTheNextUnchangedRead(_ failure: String) async throws {
        let fixture = try await Self.githubFixture(permission: "write")
        let github = try #require(fixture.github)
        try await fixture.say("A recoverable answer")
        try await fixture.say("Another answer from the same author")
        await github.setPermission("write", for: "other-writer")
        await github.addComment("Unaffected guidance", on: 2, by: "other-writer")
        await github.failNextPermission(for: fixture.login, with: failure)

        let failed = try #require(await fixture.tracker.ticket("GH-2"))
        #expect(!failed.comments.contains { $0.text == "A recoverable answer" && $0.isHumanInput })
        #expect(!failed.comments.contains { $0.text == "Another answer from the same author" && $0.isHumanInput })
        #expect(failed.comments.contains { $0.text == "Unaffected guidance" && $0.isHumanInput })
        #expect(await github.permissionReads(for: fixture.login) == 1)

        let recovered = try #require(await fixture.tracker.ticket("GH-2"))
        #expect(recovered.comments.contains { $0.text == "A recoverable answer" && $0.isHumanInput })
        #expect(recovered.comments.contains { $0.text == "Another answer from the same author" && $0.isHumanInput })
        #expect(await github.permissionReads(for: fixture.login) == 2)
        _ = await fixture.tracker.ticket("GH-2")
        #expect(await github.permissionReads(for: fixture.login) == 2)
    }

    @Test func anExpiredSuccessfulPermissionIsNotUsedWhenItsRefreshFails() async throws {
        let fixture = try await Self.githubFixture(permission: "write")
        let github = try #require(fixture.github)
        try await fixture.say("Previously trusted guidance")
        #expect(await fixture.tracker.ticket("GH-2")?.comments.contains { $0.isHumanInput } == true)

        fixture.clock.advance(by: 301)
        await github.failNextPermission(for: fixture.login, with: "HTTP 429")
        let failed = try #require(await fixture.tracker.ticket("GH-2"))
        #expect(!failed.comments.contains { $0.text == "Previously trusted guidance" && $0.isHumanInput })
        #expect(await github.permissionReads(for: fixture.login) == 2)

        let recovered = try #require(await fixture.tracker.ticket("GH-2"))
        #expect(recovered.comments.contains { $0.text == "Previously trusted guidance" && $0.isHumanInput })
        #expect(await github.permissionReads(for: fixture.login) == 3)
    }

    @Test func commentsWrittenInTheLocalAppReachTicketAndParentContexts() async throws {
        let fixture = try await Self.localFixture()
        try await fixture.say("Ticket guidance", on: "GH-2")
        try await fixture.say("Parent guidance", on: "GH-1")
        try await Self.expectContexts(fixture, containsInput: true)
    }

    @Test(arguments: Self.inputUses)
    func localAppCommentsStillAnswerCorrectReplyToEscalationsAndGivePreviewFeedback(_ use: String) async throws {
        let fixture = try await Self.localFixture()
        try await Self.exerciseInput(use, fixture: fixture, trusted: true)
    }

}

private extension GH_116Tests {
    static let inputUses = [
        "answer", "suggestion-correction", "replan-correction", "escalation-answer",
        "escalation-reply", "test-feedback", "preview-answer", "preview-feedback", "preview-correction",
    ]

    static func expectContexts(_ fixture: GH116Fixture, containsInput: Bool) async throws {
        _ = try await fixture.reconciler.propose(
            fixture.spec, ticketKey: "GH-2", clarifications: [], log: nil)
        let breakdown = try #require(await fixture.agents.requests.last)
        #expect(breakdown.agentContext.ticketComments.contains { $0.text == "Ticket guidance" } == containsInput)
        #expect(breakdown.agentContext.parent?.comments.contains { $0.text == "Parent guidance" } == containsInput)

        try await fixture.seed([])
        let node = try #require(await fixture.node())
        let roles: [AgentRole] = containsInput ? [.testAuthor] : [.testAuthor, .implementer, .verifier, .diagnoser]
        for role in roles {
            let task = await fixture.reconciler.makeTask(
                node, run: "run-context", in: fixture.workspace.root, log: nil, for: role)
            #expect(task.agentContext.ticketComments.contains { $0.text == "Ticket guidance" } == containsInput)
            #expect(task.agentContext.parent?.comments.contains { $0.text == "Parent guidance" } == containsInput)
        }
    }

    static func exerciseInput(
        _ use: String, fixture: GH116Fixture, trusted: Bool, rejectingNoise: Bool = false
    ) async throws {
        if use.hasPrefix("preview-") {
            if use == "preview-answer" {
                try await fixture.ask("❓ The decomposer has questions before it can propose a breakdown\n1. Which greeting?")
            } else if use == "preview-correction" {
                try await fixture.ask("💡 Proceeding on suggested answers for this preview\n1. Which greeting?\n   Suggested answer: Hello")
            } else {
                try await fixture.ask("🔍 Preview #1. Nothing has been created.")
            }
            let input = use == "preview-correction" ? "1. Answer: Welcome" : "Use the welcome greeting"
            try await fixture.say(input)
            if rejectingNoise { try await Self.addUntrustedNoise(to: fixture) }
            try await fixture.signal(.preview)
            let request = try #require(await fixture.agents.requests.last)
            #expect(request.agentContext.ticketComments.contains { $0.text == input } == trusted)
            if rejectingNoise {
                #expect(!request.agentContext.ticketComments.contains { $0.text.contains("OUTSIDER") })
            }
            if use != "preview-feedback" {
                let answer = use == "preview-correction" ? "Welcome" : input
                #expect(request.clarifications.contains { $0.answer == answer } == trusted)
                #expect(request.clarifications.isEmpty == !trusted)
            }
            return
        }

        var kinds: [EventKind] = []
        if use == "suggestion-correction" {
            kinds = [.suggestionsReported(role: .decomposer, questions: [
                AgentQuestion(question: "Which greeting?", suggestion: "Hello"),
            ])]
        } else if use == "escalation-reply" {
            kinds = [.flagSet(.escalated, reason: "Breakdown failed")]
        } else if use != "replan-correction" {
            kinds = [.flagSet(.needsInput, reason: "Waiting for input")]
            if use != "test-feedback" {
                kinds.insert(.questionsRaised(role: .decomposer, questions: ["Which greeting?"]), at: 0)
            }
            if use == "escalation-answer" { kinds.append(.flagSet(.escalated, reason: "Needs a person")) }
        }
        try await fixture.seed(kinds)
        if use == "suggestion-correction" {
            try await fixture.ask("💡 Proceeding on suggested answers\n1. Which greeting?\n   Suggested answer: Hello")
        } else if use == "escalation-reply" {
            try await fixture.ask("⚠️ Needs a human: breakdown failed. Fix the ticket, then add harness:retry.")
        } else if use != "replan-correction" {
            try await fixture.ask("❓ Needs input\n1. Which greeting?")
        }
        let input = use == "suggestion-correction" ? "1: Welcome" : "Use the welcome greeting"
        try await fixture.say(input)
        if rejectingNoise { try await Self.addUntrustedNoise(to: fixture) }
        try await fixture.signal(use == "replan-correction" ? .replan : .retry)
        let node = try #require(await fixture.node())

        if ["replan-correction", "escalation-reply"].contains(use) {
            _ = try await fixture.reconciler.propose(
                node.spec, ticketKey: "GH-2", clarifications: node.clarifications, log: nil)
            let request = try #require(await fixture.agents.requests.last)
            #expect(request.agentContext.ticketComments.contains { $0.text == input } == trusted)
            if rejectingNoise {
                #expect(!request.agentContext.ticketComments.contains { $0.text.contains("OUTSIDER") })
            }
            #expect(!node.clarifications.contains { $0.answer == input && !trusted })
        } else {
            let answer = use == "suggestion-correction" ? "Welcome" : input
            #expect(node.clarifications.contains { $0.answer == answer } == trusted)
            if trusted {
                #expect(node.flags[.needsInput] == nil)
                #expect(node.flags[.escalated] == nil)
                let task = await fixture.reconciler.makeTask(
                    node, run: "run-answer", in: fixture.workspace.root, log: nil,
                    for: .implementer, includeComments: false)
                #expect(task.clarifications.contains { $0.answer == answer })
            } else {
                #expect(node.clarifications.isEmpty)
                if use != "suggestion-correction" { #expect(node.flags[.needsInput] != nil) }
            }
            let accepted = await fixture.ledger.allRecords().contains {
                if case .signalAccepted(ticket: "GH-2", command: .retry, reply: _) = $0.event.kind { return true }
                return false
            }
            #expect(accepted == trusted)
        }
    }

    static func addUntrustedNoise(to fixture: GH116Fixture) async throws {
        let github = try #require(fixture.github)
        for permission in ["read", "triage", "none"] {
            await github.setPermission(permission, for: permission)
            await github.addComment("1. Answer: OUTSIDER \(permission)", on: 2, by: permission)
        }
        await github.setPermission("admin", for: "automation")
        await github.addComment("1. Answer: OUTSIDER bot", on: 2, by: "automation", type: "Bot")
    }

    static func githubFixture(permission: String) async throws -> GH116Fixture {
        let github = GH116GitHub()
        await github.addIssue(1)
        await github.addIssue(2, parent: 1)
        let login = permission == "bot-login" ? "automation[bot]" : "commenter"
        let type = permission == "bot-type" ? "Bot" : "User"
        await github.setPermission(permission.hasPrefix("bot-") ? "admin" : permission, for: login)
        await github.setPermission("admin", for: "harness-user")
        let clock = GH116Clock()
        let tracker = GitHubIssuesTracker(
            repo: "acme/app", transport: github, listInterval: .zero,
            permissionRefreshInterval: .seconds(300), now: { clock.now })
        return try GH116Fixture(tracker: tracker, github: github, clock: clock, login: login, userType: type)
    }

    static func localFixture() async throws -> GH116Fixture {
        let local = LocalTracker(project: "GH", store: nil)
        await local.createTicket(title: "Parent", description: "Parent description",
                                 acceptanceCriteria: ["Parent behaviour"], by: .human("app-user"))
        await local.createTicket(title: "Greeting", description: "Greet the user",
                                 acceptanceCriteria: ["The greeting is visible"], parentKey: "GH-1", by: .human("app-user"))
        return try GH116Fixture(tracker: LocalTrackerAdapter(tracker: local), local: local, login: "app-user")
    }
}
