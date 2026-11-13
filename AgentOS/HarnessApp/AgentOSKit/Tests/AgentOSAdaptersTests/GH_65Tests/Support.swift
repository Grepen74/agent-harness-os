import Foundation
import Testing
import AgentOSCore
import AgentOSAdapters
import AgentOSSimulation

extension GH_65Tests {
    static var person: Participant { .human("GH65 reviewer") }
    static var spec: NodeSpec {
        NodeSpec(id: "wn-APP-1", kind: .composite, title: "Reader and writer", intent: "Expose stored records",
                 acceptanceCriteria: ["Reads stored records.", "Writes stored records."])
    }
    static var first: [ChildProposal] {
        [
            ChildProposal(title: "Initial reader", acceptanceCriteria: [
                "Read using the existing rule.", "Sources/Reader.swift is unchanged."
            ], touches: ["shared storage"]),
            ChildProposal(title: "Initial writer", acceptanceCriteria: ["Save a record."], touches: ["shared storage"])
        ]
    }
    static var second: [ChildProposal] {
        [
            ChildProposal(title: "Revised reader", acceptanceCriteria: [
                "Owns only read methods and applies the agreed validation.",
                "Sources/Writer.swift is unchanged."
            ], touches: ["shared storage", "read response"]),
            ChildProposal(title: "Revised writer", acceptanceCriteria: [
                "Owns only write methods and rejects a record with an empty identifier."
            ], touches: ["shared storage", "write response"])
        ]
    }
    static var clean: [ChildProposal] {
        [
            ChildProposal(title: "Validated reader", acceptanceCriteria: ["Return the stored record for its identifier."],
                          touches: ["read response"]),
            ChildProposal(title: "Validated writer", acceptanceCriteria: ["Reject records with an empty identifier."],
                          touches: ["write response"], after: [1])
        ]
    }

    enum Response: Sendable {
        case proposal([ChildProposal], AgentReport = AgentReport())
        case failure
        case cancelled
    }

    actor RecordingDecomposer: Decomposer {
        let responses: [Response]
        var requests: [BreakdownRequest] = []
        init(_ responses: [Response]) { self.responses = responses }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            guard request.spec.parent == nil else {
                return Breakdown(children: [ChildProposal(title: request.spec.title,
                    acceptanceCriteria: request.spec.acceptanceCriteria, touches: request.spec.touches)])
            }
            let index = requests.count
            requests.append(request)
            guard responses.indices.contains(index) else {
                Issue.record("Unexpected decomposer call: checker retry budget exceeded")
                throw AgentFailure("No scripted response")
            }
            switch responses[index] {
            case .proposal(let children, let report): return Breakdown(children: children, report: report)
            case .failure: throw AgentFailure("scripted decomposer failure")
            case .cancelled: throw CancellationError()
            }
        }
    }

    struct Checks: CheckRunner {
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "Scripted checks passed", log: "ok")
        }
    }

    static func team(_ agent: RecordingDecomposer) -> AgentTeam {
        AgentTeam(name: "GH65", decomposer: agent, testAuthor: ScriptedTestAuthor(), implementer: ScriptedImplementer())
    }

    static func withSimulation(
        _ responses: [Response], guesswork: Guesswork = .assumeAndReport,
        criteria: [String] = ["Reads stored records.", "Writes stored records."],
        body: (Simulation, RecordingDecomposer) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gh65-\(UUID())")
        let agent = RecordingDecomposer(responses)
        let sim = try Simulation(directory: directory, team: team(agent), checks: Checks(),
                                 policy: Policy(guesswork: guesswork))
        do {
            await sim.tracker.createTicket(title: spec.title, description: spec.intent,
                                           acceptanceCriteria: criteria, by: person)
            try await body(sim, agent)
        } catch {
            await sim.reconciler.shutdown(reason: "GH65 test cleanup")
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        await sim.reconciler.shutdown(reason: "GH65 test cleanup")
        try FileManager.default.removeItem(at: directory)
    }

    static func signal(_ command: HarnessCommand, in sim: Simulation) async {
        await sim.tracker.addLabel(command.label, to: "APP-1", by: person)
        await sim.runUntilFinished(maxRounds: 100)
    }

    static func expectProposals(_ actual: [ChildProposal], match expected: [ChildProposal]) {
        #expect(actual.count == expected.count)
        for (actual, expected) in zip(actual, expected) {
            #expect(actual.title == expected.title)
            #expect(actual.acceptanceCriteria == expected.acceptanceCriteria)
            #expect(actual.touches == expected.touches)
            #expect(actual.dependsOn == expected.dependsOn)
            #expect(actual.after == expected.after)
        }
    }

    static func expectSpecs(_ actual: [NodeSpec], match expected: [ChildProposal]) {
        #expect(actual.count == expected.count)
        for (index, pair) in zip(actual, expected).enumerated() {
            let (child, proposal) = pair
            #expect(child.title == proposal.title)
            #expect(child.acceptanceCriteria == proposal.acceptanceCriteria)
            #expect(child.touches == Set((proposal.touches ?? []).map { ComponentName.from($0) }).sorted())
            #expect(child.dependsOn == (proposal.dependsOn ?? []))
            // Fingerprints are resolved against the actual siblings, not ticket-derived child IDs.
            let earlier = Set(proposal.after ?? []).filter { $0 >= 1 && $0 <= index }.sorted()
            let expectedHashes = earlier.compactMap { position in
                actual.indices.contains(position - 1) ? actual[position - 1].specHash : nil
            }
            #expect((child.after ?? []) == expectedHashes)
        }
    }

    static func expectCheck(_ check: BreakdownCheckFeedback, proposal: [ChildProposal]) {
        expectProposals(check.proposal, match: proposal)
        #expect(check.findings == BreakdownChecker.check(proposal))
    }

    static func expectAudit(_ sim: Simulation, proposals: [[ChildProposal]], retries: Int) async throws {
        try await expectAudit(ledger: sim.ledger, proposals: proposals, retries: retries)
    }

    static func expectAudit(ledger: Ledger, proposals: [[ChildProposal]], retries: Int) async throws {
        let records = await ledger.allRecords()
        let checks = records.compactMap { record -> BreakdownCheckFeedback? in
            if case .breakdownChecked(let ticket, let check) = record.event.kind, ticket == "APP-1" { return check }
            return nil
        }
        #expect(checks.count == proposals.count)
        for (check, proposal) in zip(checks, proposals) { expectCheck(check, proposal: proposal) }
        let retryFeedback = records.compactMap { record -> BreakdownCheckFeedback? in
            if case .breakdownRetryRequested(let ticket, let feedback) = record.event.kind, ticket == "APP-1" {
                return feedback
            }
            return nil
        }
        #expect(retryFeedback.count == retries)
        for feedback in retryFeedback {
            #expect(!feedback.findings.isEmpty)
            expectCheck(feedback, proposal: first)
        }
    }

    static func humanEvidence(_ sim: Simulation) async -> String {
        let comments = await sim.tracker.ticket("APP-1")?.comments ?? []
        return comments.filter { !$0.author.isHuman }.map(\.text).joined(separator: "\n")
    }

    static func expectTicketFindings(_ sim: Simulation, proposals: [[ChildProposal]]) async {
        let comments = await sim.tracker.ticket("APP-1")?.comments.filter { !$0.author.isHuman }.map(\.text) ?? []
        let explanations = comments.flatMap { $0.components(separatedBy: "\n\n") }
        for proposal in proposals {
            for finding in BreakdownChecker.check(proposal) {
                switch finding {
                case .vagueReference(_, let title, _, let text):
                    #expect(explanations.contains {
                        $0.contains(title) && $0.contains(text)
                            && matches($0, #"vague|refer(s|ence|ring).{0,100}(rule|stat)|rule.{0,100}(explicit|spell|state)"#)
                    }, "Explain the vague-reference finding, not merely the proposed criterion")
                case .scopeCriterion(_, let title, _, let text):
                    #expect(explanations.contains {
                        $0.contains(title) && $0.contains(text)
                            && matches($0, #"scope|unchanged.{0,100}(criterion|criteria)|lasting behavio|file.{0,100}(constraint|restriction)"#)
                    }, "Explain why the path-based scope criterion is a finding")
                case .unorderedOverlap(_, let first, _, let second, let shared):
                    #expect(explanations.contains { explanation in
                        explanation.contains(first) && explanation.contains(second)
                            && shared.allSatisfy { explanation.localizedCaseInsensitiveContains($0) }
                            && matches(explanation, #"overlap|unordered|without.{0,40}order|no.{0,40}(after|order)"#)
                    }, "Explain the overlap and identify both siblings and every shared component")
                }
            }
        }
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "(?s)" + pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func dataBlock(_ name: String, in prompt: String) throws -> String {
        let start = try #require(prompt.range(of: "<<<\(name)"))
        let newline = try #require(prompt[start.upperBound...].firstIndex(of: "\n"))
        let end = try #require(prompt.range(of: "\(name)>>>", range: newline..<prompt.endIndex))
        return String(prompt[prompt.index(after: newline)..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
