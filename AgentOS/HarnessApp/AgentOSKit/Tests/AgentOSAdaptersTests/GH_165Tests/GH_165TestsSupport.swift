import Foundation
import Testing
@testable import AgentOSCore
import AgentOSTestSupport

extension GH_165Tests {
    enum InvalidShape: String, CaseIterable, Sendable {
        case multiple, notLast, oneOther, lone

        var positions: [Int] {
            switch self {
            case .multiple: [3, 4]
            case .notLast, .lone: [1]
            case .oneOther: [2]
            }
        }
        var problemPattern: String {
            switch self {
            case .multiple:
                #"\b(more than one|multiple|several|second|only one|at most one|a single)\b.{0,80}\bintegration\s+child(?:ren)?\b|\bintegration\s+child(?:ren)?\b.{0,80}\b(more than one|multiple|only one|at most one)\b"#
            case .notLast:
                #"\b(last|final)\s+(proposed\s+)?child\b|\b(is not|isn't|not|must be)\s+last\b|\bend\s+of\s+(the\s+)?(proposal|breakdown|child list|proposed children)\b"#
            case .oneOther:
                #"\b(at least|fewer than|needs?|requires?)\s+(two|2)\s+(other\s+children|ordinary\s+children|siblings)\b|\b(only|exactly)\s+(one|1)\s+(other\s+child|ordinary\s+child|sibling)\b"#
            case .lone:
                #"\b(lone|only|single)\s+(integration\s+)?(proposal|child)\b|\b(no|without)\s+(other\s+children|ordinary\s+children|siblings)\b|\bintegration\s+(proposal|child)\b.{0,60}\b(alone|by itself)\b"#
            }
        }
        private var ordinaryCorrectionPattern: String {
            #"\b(remove|clear)\s+(the\s+|its\s+|this child's\s+)?integration\s+(mark|flag)\b|\bunmark\s+(it|this child|the integration child)\b|\b(make|mark|treat|propose)\b[^.!?;\n]{0,60}\b(ordinary|non-integration)\s+(child|leaf)\b"#
        }
        var correctionPattern: String {
            switch self {
            case .multiple:
                #"\b(keep|retain|choose|mark|allow|use)\b[^.!?;\n]{0,40}\b(only one|at most one|one|a single)\s+integration\s+child\b|\b(only one|at most one)\s+integration\s+child\s+(is|may be)\s+(allowed|marked)\b|\b(remove|unmark|clear)\b[^.!?;\n]{0,40}\b(extra|additional)\s+integration\s+(marks?|children)\b|"# + ordinaryCorrectionPattern
            case .notLast:
                #"\b(move|place|put|make|propose|reorder)\b[^.!?;\n]{0,80}\b(last|final)\s+(proposed\s+)?(child|position)\b|\b(move|place|put|reorder)\s+(it|this child|the integration child)\s+(to\s+the\s+end|last)\b|"# + ordinaryCorrectionPattern
            case .oneOther:
                #"\b(add|propose|include)\b[^.!?;\n]{0,40}\b(another\s+(ordinary\s+)?child|(at least\s+)?(one|1)\s+more\s+(ordinary\s+)?(child|sibling)|(at least\s+)?(two|2)\s+(other\s+children|ordinary\s+children|siblings))\b|"# + ordinaryCorrectionPattern
            case .lone:
                #"\b(add|propose|include)\b[^.!?;\n]{0,40}\b(at least\s+)?(two|2)\s+(other\s+children|ordinary\s+children|siblings)\b|\b(make|keep|treat|build|propose)\b[^.!?;\n]{0,60}\b(parent|ticket|proposal|it)\b[^.!?;\n]{0,40}\b(ordinary\s+)?leaf\b|"# + ordinaryCorrectionPattern
            }
        }
    }

    enum Quality: CaseIterable, Sendable {
        case vague, scope, tooMany, repeated, overlap
        func matches(_ finding: BreakdownFinding) -> Bool {
            switch (self, finding) {
            case (.vague, .vagueReference), (.scope, .scopeCriterion), (.tooMany, .tooManyCriteria),
                 (.repeated, .repeatedCriterion), (.overlap, .unorderedOverlap): true
            default: false
            }
        }
    }

    static var ticket: Ticket {
        Ticket(key: "GH-165-fixture", title: "Store and retrieve records",
               description: "A person can retrieve a record they stored.",
               acceptanceCriteria: ["Store a record.", "Retrieve a stored record."],
               createdBy: .human("Acceptance reviewer"))
    }
    static var rootSpec: NodeSpec { Planner.rootSpec(for: Self.ticket) }

    static func child(
        _ title: String, criteria: [String]? = nil, touches: [String]? = nil,
        after: [Int]? = nil, integration: Bool? = nil
    ) throws -> ChildProposal {
        var object: [String: Any] = [
            "title": title, "acceptanceCriteria": criteria ?? ["\(title) returns a record."],
            "touches": touches ?? [title],
        ]
        if let after { object["after"] = after }
        if let integration { object["integration"] = integration }
        return try JSONDecoder().decode(
            ChildProposal.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func withoutMarks(_ children: [ChildProposal]) throws -> [ChildProposal] {
        try children.map { child in
            var object = try #require(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(child)) as? [String: Any])
            object.removeValue(forKey: "integration")
            return try JSONDecoder().decode(
                ChildProposal.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    static func invalidProposal(_ shape: InvalidShape, prefix: String = "") throws -> [ChildProposal] {
        let store = try Self.child(prefix + "Store")
        let read = try Self.child(prefix + "Read")
        let integration = try Self.child(prefix + "Combined flow", integration: true)
        switch shape {
        case .multiple: return [store, read, integration, try Self.child(prefix + "Combined audit", integration: true)]
        case .notLast: return [integration, store, read]
        case .oneOther: return [store, integration]
        case .lone: return [integration]
        }
    }

    static func cleanProposal() throws -> [ChildProposal] {
        [try Self.child("Corrected store"), try Self.child("Corrected read", after: [1])]
    }

    static func qualityProposal(_ quality: Quality, integration: Bool) throws -> [ChildProposal] {
        var children = [
            try Self.child("Retry store"),
            try Self.child("Retry read"),
            try Self.child("Retry combined flow", integration: integration),
        ]
        switch quality {
        case .vague: children[0].acceptanceCriteria = ["Read according to the existing rule."]
        case .scope: children[0].acceptanceCriteria = ["Sources/Store.swift is unchanged."]
        case .tooMany:
            children[0].acceptanceCriteria = (1...(BreakdownChecker.maxCriteriaPerChild + 1)).map {
                "Retrieving record \($0) returns its stored contents."
            }
        case .repeated:
            children[0].acceptanceCriteria = ["Retrieving a record returns its stored contents."]
            children[1].acceptanceCriteria = ["Retrieving a record returns its stored contents."]
        case .overlap:
            children[0].touches = ["Shared"]
            children[1].touches = ["Shared"]
        }
        return children
    }

    static func structuralFindings(_ findings: [BreakdownFinding]) -> [BreakdownFinding] {
        findings.filter { finding in
            !Quality.allCases.contains { $0.matches(finding) }
        }
    }
    static func overlaps(_ findings: [BreakdownFinding]) -> [BreakdownFinding] {
        findings.filter { if case .unorderedOverlap = $0 { return true }; return false }
    }
    static func repeated(_ findings: [BreakdownFinding]) -> [BreakdownFinding] {
        findings.filter { if case .repeatedCriterion = $0 { return true }; return false }
    }
    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "(?s)" + pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func namesChild(_ text: String, position: Int, title: String) -> Bool {
        let location = #"\b(?:child(?:\s+(?:at\s+)?position)?|position)\s+"# + String(position) + #"\b"#
        let name = NSRegularExpression.escapedPattern(for: title)
        let namedChild = #"[^\p{L}\p{N}\n]*(?:(?:named|titled|title)\s*[:=]?\s*)?"# + name
        let precedingChildren = #"(?:\d+\s+"[^"\n]+"\s*(?:,\s*(?:and\s+)?|and\s+))*"#
        let listLocation = #"\b(?:children(?:\s+at\s+positions)?|child positions|positions)\s+"#
            + precedingChildren + String(position) + #"\b"#
        return Self.matches(text, location + namedChild
                            + "|" + name + #"[^\p{L}\p{N}\n]*(?:at\s+)?"# + location
                            + "|" + listLocation + namedChild)
    }
    static func expectProposal(_ actual: [ChildProposal], _ expected: [ChildProposal]) throws {
        let actualJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(actual)) as? NSArray)
        let expectedJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? NSArray)
        #expect(actualJSON == expectedJSON)
    }

    static func expectSingleRetry(
        _ fixture: Fixture, first: [ChildProposal], second: [ChildProposal]
    ) async throws {
        let requests = await fixture.decomposer.requests
        try #require(requests.count == 2, "Exactly one retry must be made.")
        #expect(requests[0].checkerFeedback.isEmpty)
        try #require(requests[1].checkerFeedback.count == 1)
        let feedback = requests[1].checkerFeedback[0]
        try Self.expectProposal(feedback.proposal, first)
        #expect(feedback.findings == BreakdownChecker.check(first))
        #expect(!feedback.findings.isEmpty)
        let records = await fixture.ledger.allRecords()
        let retries = records.compactMap { record -> BreakdownCheckFeedback? in
            if case .breakdownRetryRequested(let ticket, let feedback) = record.event.kind,
               ticket == Self.ticket.key { return feedback }
            return nil
        }
        try #require(retries.count == 1)
        try Self.expectProposal(retries[0].proposal, first)
        #expect(retries[0].findings == feedback.findings)
        let checks = records.compactMap { record -> BreakdownCheckFeedback? in
            if case .breakdownChecked(let ticket, let check) = record.event.kind,
               ticket == Self.ticket.key { return check }
            return nil
        }
        try #require(checks.count == 2)
        try Self.expectProposal(checks[0].proposal, first)
        try Self.expectProposal(checks[1].proposal, second)
        #expect(checks[1].findings == BreakdownChecker.check(second))
    }

    static func withFixture(
        _ fixture: Fixture, body: @escaping @Sendable () async throws -> Void
    ) async throws {
        do { try await withHangGuard("GH-165 breakdown acceptance test", body) }
        catch {
            await fixture.reconciler.shutdown(reason: "GH-165 cleanup")
            throw error
        }
        await fixture.reconciler.shutdown(reason: "GH-165 cleanup")
    }

    final class Fixture: Sendable {
        let ledger: Ledger
        let tracker = Tracker()
        let decomposer: RecordingDecomposer
        let reconciler: Reconciler

        init(proposals: [[ChildProposal]]) throws {
            ledger = try Ledger()
            decomposer = RecordingDecomposer(proposals: proposals)
            let services = BreakdownServices()
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: services, workspace: services,
                artifacts: services, checks: services,
                team: AgentTeam(name: "GH-165", decomposer: decomposer,
                                testAuthor: services, implementer: services))
        }

        func breakDown(buildApproved: Bool = false) async throws {
            let spec = GH_165Tests.rootSpec
            var events: [EventKind] = [
                .nodeCreated(spec: spec, ticket: GH_165Tests.ticket.key), .gateOpened(.breakdown)
            ]
            if buildApproved { events.append(.gateOpened(.build)) }
            try await ledger.append(events.map {
                LedgerEvent(node: spec.id, by: .human("Acceptance reviewer"), kind: $0)
            })
            let state = await ledger.workingState()
            let node = try #require(state.nodes[spec.id])
            _ = try await reconciler.breakDown(node, in: state)
        }

        func preview() async throws {
            await tracker.requestPreview()
            let report = await reconciler.runRound(waitForAgents: true)
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
            await reconciler.waitForAgents()
        }
    }

    actor RecordingDecomposer: Decomposer {
        let proposals: [[ChildProposal]]
        private(set) var requests: [BreakdownRequest] = []
        init(proposals: [[ChildProposal]]) { self.proposals = proposals }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            let index = requests.count
            requests.append(request)
            guard proposals.indices.contains(index) else {
                Issue.record("The decomposer exceeded its scripted retry budget.")
                throw AgentFailure("GH-165 unexpected decomposer call")
            }
            return Breakdown(children: proposals[index])
        }
    }

    actor Tracker: TrackerAdapter {
        private var signals: [Signal] = []
        private(set) var comments: [String] = []
        private(set) var created: [NodeSpec] = []
        func requestPreview() {
            signals.append(Signal(ticket: GH_165Tests.ticket.key, command: .preview,
                                  setBy: .human("Acceptance reviewer")))
        }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? { key == GH_165Tests.ticket.key ? GH_165Tests.ticket : nil }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            comments.append(reply)
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            created.append(spec)
            return "GH-165-child-\(created.count)"
        }
        func comment(on key: String, _ text: String) { comments.append(text) }
        func setStatus(of key: String, to status: String) {}
    }

    struct BreakdownServices: Workspace, ExternalDependencySource, ArtifactStore, CheckRunner,
                              TestAuthor, Implementer {
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: id)
        }
        func createWorktree(for id: NodeID) async throws -> URL { throw AgentFailure("Unexpected worktree") }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Unexpected commit")
        }
        func head(of directory: URL) async throws -> String { throw AgentFailure("Unexpected HEAD read") }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { throw AgentFailure("Unexpected rebase") }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { throw AgentFailure("Unexpected landing") }
        func existingComponents() -> [String] { ["Store", "Read"] }
        func prepareBuild(in directory: URL) async throws { throw AgentFailure("Unexpected build") }
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            throw AgentFailure("Unexpected artifact")
        }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("A breakdown-only fixture must not run build checks.")
            return CheckOutput(passed: false, summary: "Unexpected checks", log: "")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Unexpected test author")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport { throw AgentFailure("Unexpected implementer") }
    }
}
