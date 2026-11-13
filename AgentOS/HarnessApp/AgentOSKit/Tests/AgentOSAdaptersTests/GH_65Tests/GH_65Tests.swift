// Expected API: BreakdownRequest.checkerFeedback defaults to [] of Codable BreakdownCheckFeedback
// (proposal, findings). Ticket-keyed breakdownChecked and breakdownRetryRequested ledger events retain
// those values; Preview.breakdownWarnings exposes remaining findings, defaulting to [] for old previews.
// CopilotDecomposer.prompt(for:) exposes the production prompt, including delimited checker feedback.
import Foundation
import Testing
import AgentOSCore
import AgentOSAdapters
import AgentOSSimulation

@Suite(.timeLimit(.minutes(1)))
struct GH_65Tests {
    @Test
    static func retryThenWarnPersistsBothChecksAndApprovesTheStoredSecondProposal() async throws {
        try await withSimulation([.proposal(first), .proposal(second)]) { sim, agent in
            await signal(.preview, in: sim)
            let requests = await agent.requests
            try #require(requests.count == 2)
            #expect(requests[0].checkerFeedback.isEmpty)
            try #require(requests[1].checkerFeedback.count == 1)
            expectCheck(requests[1].checkerFeedback[0], proposal: first)
            #expect(requests[1].clarifications == requests[0].clarifications)

            let state = await sim.ledger.workingState()
            #expect(state.nodes.isEmpty)
            let preview = try #require(state.previews["APP-1"])
            expectSpecs(preview.proposal, match: second)
            #expect(preview.breakdownWarnings == BreakdownChecker.check(second))
            try await expectAudit(sim, proposals: [first, second], retries: 1)
            await expectTicketFindings(sim, proposals: [first, second])
            let comments = await humanEvidence(sim)
            #expect(matches(comments, #"retr(y|ied|ying)"#))
            #expect(matches(comments, #"(initial|first).{0,100}(check|finding)|(check|finding).{0,100}(initial|first)"#))
            #expect(matches(comments, #"(second|2nd|retry).{0,100}check|check.{0,100}(second|2nd|retry)"#))
            #expect(comments.contains("harness:go"))
            #expect(matches(comments, #"(approv|accept|proceed).{0,100}(anyway|despite|warning)"#))
            #expect(comments.contains("harness:preview"))
            #expect(matches(comments, #"(comment|edit).{0,160}harness:preview"#))
            let before = await sim.ledger.allRecords()
            #expect(!before.contains { if case .gateOpened = $0.event.kind { return true }; return false })

            let replay = try Simulation(directory: sim.directory, team: team(agent), checks: Checks())
            let replayed = try #require(await replay.ledger.workingState().previews["APP-1"])
            expectSpecs(replayed.proposal, match: second)
            #expect(replayed.breakdownWarnings == BreakdownChecker.check(second))
            try await expectAudit(replay, proposals: [first, second], retries: 1)

            await signal(.go, in: replay)
            #expect(await agent.requests.count == 2)
            let adopted = await replay.ledger.workingState()
            let root = try #require(adopted.node(forTicket: "APP-1"))
            expectSpecs(root.children.compactMap { adopted.nodes[$0]?.spec }, match: second)
            #expect(root.gates == Set([Gate.breakdown, .build]))
            #expect(root.openQuestions.isEmpty)
            #expect(root.allAssumptions.isEmpty)
            #expect(root.flags[.needsInput] == nil)
            #expect(root.phase == .proven)
            try await expectAudit(replay, proposals: [first, second], retries: 1)
            await expectTicketFindings(replay, proposals: [first, second])
        }
    }

    @Test
    static func cleanFirstProposalIsCheckedWithoutACheckerRetry() async throws {
        try await withSimulation([.proposal(clean)]) { sim, agent in
            await signal(.preview, in: sim)
            #expect(await agent.requests.count == 1)
            let preview = try #require(await sim.ledger.workingState().previews["APP-1"])
            expectSpecs(preview.proposal, match: clean)
            #expect(preview.breakdownWarnings.isEmpty)
            try await expectAudit(sim, proposals: [clean], retries: 0)
            await signal(.breakdown, in: sim)
            #expect(await agent.requests.count == 1)
            let adopted = await sim.ledger.workingState()
            let root = try #require(adopted.node(forTicket: "APP-1"))
            expectSpecs(root.children.compactMap { adopted.nodes[$0]?.spec }, match: clean)
            try await expectAudit(sim, proposals: [clean], retries: 0)
        }
    }

    @Test
    static func correctedSecondProposalHasNoRemainingWarningsButKeepsTheInitialEvidence() async throws {
        try await withSimulation([.proposal(first), .proposal(clean)]) { sim, agent in
            await signal(.preview, in: sim)
            #expect(await agent.requests.count == 2)
            let preview = try #require(await sim.ledger.workingState().previews["APP-1"])
            expectSpecs(preview.proposal, match: clean)
            #expect(preview.breakdownWarnings.isEmpty)
            try await expectAudit(sim, proposals: [first, clean], retries: 1)
            await expectTicketFindings(sim, proposals: [first])
            let comments = await humanEvidence(sim)
            #expect(matches(comments, #"(second|2nd|retry).{0,160}(clean|no findings|no warnings|0 findings|passed)"#))
            #expect(matches(comments, #"retr(y|ied|ying)"#))
        }
    }

    @Test
    static func statedOwnershipRemainsAdvisoryAndDoesNotStopAlreadyAuthorizedWork() async throws {
        try await withSimulation([.proposal(first), .proposal(second)], guesswork: .ask) { sim, agent in
            await signal(.go, in: sim)
            #expect(await agent.requests.count == 2)
            let state = await sim.ledger.workingState()
            let root = try #require(state.node(forTicket: "APP-1"))
            expectSpecs(root.children.compactMap { state.nodes[$0]?.spec }, match: second)
            #expect(root.gates == Set([Gate.breakdown, .build]))
            #expect(root.phase == .proven)
            #expect(root.openQuestions.isEmpty)
            #expect(root.allAssumptions.isEmpty)
            #expect(root.flags[.needsInput] == nil)
            #expect(root.flags[.escalated] == nil)
            #expect(BreakdownChecker.check(second).contains {
                if case .unorderedOverlap = $0 { return true }; return false
            })
            try await expectAudit(sim, proposals: [first, second], retries: 1)
            await expectTicketFindings(sim, proposals: [first, second])
            let comments = await humanEvidence(sim)
            #expect(comments.contains("harness:replan"))
            #expect(matches(comments, #"comment.{0,200}harness:replan"#))
            let records = await sim.ledger.allRecords()
            #expect(records.allSatisfy {
                if case .gateOpened = $0.event.kind { return $0.event.by.isHuman }
                return true
            })
        }
    }

    @Test
    static func warningsDoNotOpenTheBuildGateWhenOnlyBreakdownWasApproved() async throws {
        try await withSimulation([.proposal(first), .proposal(second)]) { sim, _ in
            await signal(.breakdown, in: sim)
            let state = await sim.ledger.workingState()
            let root = try #require(state.node(forTicket: "APP-1"))
            #expect(root.gates == Set([Gate.breakdown]))
            expectSpecs(root.children.compactMap { state.nodes[$0]?.spec }, match: second)
            #expect(root.children.allSatisfy { state.nodes[$0]?.phase == .ready })
            #expect(root.openQuestions.isEmpty)
            #expect(root.allAssumptions.isEmpty)
            try await expectAudit(sim, proposals: [first, second], retries: 1)
        }
    }

    @Test
    static func eachFreshPreviewAndReplanHasItsOwnSingleRetryBudget() async throws {
        try await withSimulation([
            .proposal(first), .proposal(second), .proposal(first), .proposal(second),
            .proposal(first), .proposal(second)
        ]) { sim, agent in
            await signal(.preview, in: sim)
            await signal(.preview, in: sim)
            #expect(await agent.requests.count == 4)
            await signal(.breakdown, in: sim)
            #expect(await agent.requests.count == 4)
            await sim.tracker.addComment("Please reconsider the division of responsibility.", to: "APP-1", by: person)
            await signal(.replan, in: sim)
            await signal(.breakdown, in: sim)
            let requests = await agent.requests
            try #require(requests.count == 6)
            for index in [0, 2, 4] {
                #expect(requests[index].checkerFeedback.isEmpty)
                try #require(requests[index + 1].checkerFeedback.count == 1)
                expectCheck(requests[index + 1].checkerFeedback[0], proposal: first)
            }
            try await expectAudit(sim, proposals: [first, second, first, second, first, second], retries: 3)
        }
    }

    @Test
    static func readinessRejectionNeverCallsTheDecomposerOrChecker() async throws {
        try await withSimulation([.proposal(first)], criteria: []) { sim, agent in
            await signal(.preview, in: sim)
            #expect(await agent.requests.isEmpty)
            #expect(await sim.ledger.workingState().previews["APP-1"] == nil)
            try await expectAudit(sim, proposals: [], retries: 0)
        }
    }

    @Test(arguments: [false, true])
    static func questionsAndAskModeAssumptionsAreHandledBeforeChecking(retry: Bool) async throws {
        for report in [AgentReport(questions: ["Which response should the reader return?"]),
                       AgentReport(assumptions: ["The reader returns an empty response."])] {
            let response = Response.proposal(first, report)
            let responses: [Response] = retry ? [.proposal(first), response] : [response]
            try await withSimulation(responses, guesswork: .ask) { sim, agent in
                await signal(.preview, in: sim)
                #expect(await agent.requests.count == (retry ? 2 : 1))
                #expect(await sim.ledger.workingState().previews["APP-1"] == nil)
                try await expectAudit(sim, proposals: retry ? [first] : [], retries: retry ? 1 : 0)
                let comments = await humanEvidence(sim)
                #expect(comments.contains(report.questions.first?.question ?? report.assumptions[0]))
                #expect(comments.contains("harness:preview"))
            }
        }
    }

    @Test(arguments: [false, true])
    static func failedOrCancelledRetryCannotPublishOrCreateChildren(cancelled: Bool) async throws {
        try await withSimulation([.proposal(first), cancelled ? .cancelled : .failure]) { sim, agent in
            await signal(.go, in: sim)
            #expect(await agent.requests.count == 2)
            let state = await sim.ledger.workingState()
            let root = try #require(state.node(forTicket: "APP-1"))
            #expect(root.children.isEmpty)
            #expect(state.previews["APP-1"] == nil)
            #expect(root.phase != .proven)
            if !cancelled {
                #expect(root.flags[.escalated] != nil)
                let comments = await humanEvidence(sim)
                #expect(comments.contains("scripted decomposer failure"))
                #expect(comments.contains("harness:retry"))
            }
            try await expectAudit(sim, proposals: [first], retries: 1)
        }
    }

    @Test
    static func retryFeedbackNeverBecomesAHumanClarification() async throws {
        try await withSimulation([
            .proposal([], AgentReport(questions: ["Which response?"])),
            .proposal(first), .proposal(second)
        ]) { sim, agent in
            await signal(.preview, in: sim)
            await sim.tracker.addComment("Return a JSON object with a status field.", to: "APP-1", by: person)
            await signal(.preview, in: sim)
            let requests = await agent.requests
            try #require(requests.count == 3)
            #expect(requests[1].clarifications == [
                Clarification(questions: ["Which response?"], answer: "Return a JSON object with a status field.")
            ])
            #expect(requests[2].clarifications == requests[1].clarifications)
            #expect(requests[1].checkerFeedback.isEmpty)
            try #require(requests[2].checkerFeedback.count == 1)
            expectCheck(requests[2].checkerFeedback[0], proposal: first)
        }
    }

    @Test
    static func copilotPromptCarriesStructuredFeedbackSeparatelyFromHumanAnswers() throws {
        let feedback = BreakdownCheckFeedback(proposal: first, findings: BreakdownChecker.check(first))
        let request = BreakdownRequest(
            spec: spec, clarifications: [Clarification(questions: ["Which response?"], answer: "Human answer sentinel")],
            checkerFeedback: [feedback])
        let prompt = CopilotDecomposer.prompt(for: request)
        let block = try dataBlock("CHECKER_FEEDBACK", in: prompt)
        let actual = try #require(JSONSerialization.jsonObject(with: Data(block.utf8)) as? NSArray)
        let expected = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([feedback])) as? NSArray)
        #expect(actual == expected)
        #expect(!block.contains("Human answer sentinel"))
        #expect(try dataBlock("ANSWERS", in: prompt).contains("Human answer sentinel"))
        #expect(matches(prompt, #"(correct|revise|fix).{0,160}proposal|proposal.{0,160}(correct|revise|fix)"#))
        #expect(matches(prompt, #"feedback.{0,100}data|data.{0,100}feedback"#))
    }

    @Test
    static func requestsAndPromptsWithoutFeedbackRemainSupported() {
        let request = BreakdownRequest(spec: spec)
        #expect(request.checkerFeedback.isEmpty)
        let prompt = CopilotDecomposer.prompt(for: request)
        #expect(prompt.contains(spec.title))
        #expect(!prompt.contains("<<<CHECKER_FEEDBACK"))
    }

    @Test
    static func oldEventsAndPreviewsWithoutCheckerEvidenceStillDecodeAndReplay() async throws {
        // Literal legacy payloads, not an encoding made by the new event implementation.
        let oldSignal = Data(#"{"signalAccepted":{"ticket":"APP-1","command":"preview","reply":"posted"}}"#.utf8)
        let signalKind = try JSONDecoder().decode(EventKind.self, from: oldSignal)
        if case .signalAccepted(let ticket, let command, let reply) = signalKind {
            #expect(ticket == "APP-1")
            #expect(command == .preview)
            #expect(reply == "posted")
        } else { Issue.record("Legacy signal event changed meaning") }
        let children = [spec]
        let legacyPreview: [String: Any] = ["previewRecorded": [
            "ticket": "APP-1", "number": 1, "specHash": spec.specHash,
            "proposal": try JSONSerialization.jsonObject(with: JSONEncoder().encode(children))
        ]]
        let kind = try JSONDecoder().decode(EventKind.self, from: JSONSerialization.data(withJSONObject: legacyPreview))
        let store = InMemoryLedgerStore()
        let ledger = try Ledger(store: store)
        try await ledger.append([
            LedgerEvent(node: nil, by: .reconciler, kind: signalKind),
            LedgerEvent(node: nil, by: .reconciler, kind: kind)
        ])
        let replay = try Ledger(store: store)
        let preview = try #require(await replay.workingState().previews["APP-1"])
        #expect(preview.proposal == children)
        #expect(preview.breakdownWarnings.isEmpty)
        try await expectAudit(ledger: replay, proposals: [], retries: 0)
    }
}
