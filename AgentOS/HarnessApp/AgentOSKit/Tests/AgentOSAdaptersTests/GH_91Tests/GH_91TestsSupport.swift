import Foundation
import Testing
import AgentOSCore
import AgentOSAdapters

extension GH_91Tests {
    static let tip = String(repeating: "a", count: 40)
    static let oldCommit = String(repeating: "9", count: 40)
    static let repository = "acceptance/publishing"

    enum VerificationHold: CaseIterable, Sendable { case unfinishedLeaf, notRun, failed, oldCommit }
    enum FailurePoint: CaseIterable, Sendable {
        case push, open, lostOpenResponse, update
        var message: String {
            switch self {
            case .push: "origin refused push"
            case .open: "GitHub refused open"
            case .lostOpenResponse: "GitHub response lost after creating PR"
            case .update: "GitHub refused update"
            }
        }
    }
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Fixture: Sendable {
        let ledger: Ledger
        let root: NodeSpec
        let leaves: [NodeSpec]
        let proofs: [AcceptanceCriterionProof]
        let leafEvidence: [Evidence]
        let finalEvidence: [Evidence]
        let tracker: Tracker
        let github: GitHub
        let git: Git
        let enabled: Bool
        var branch: String { "agentos/GH-91" }

        func publisher(ledger replacement: Ledger? = nil) -> PullRequestPublicationCoordinator {
            PullRequestPublicationCoordinator(
                ledger: replacement ?? ledger, tracker: tracker, repository: GH_91Tests.repository,
                policy: GH_91Tests.policy(enabled: enabled), transport: github,
                git: { [git] arguments in try await git.run(arguments) }
            )
        }

        func request(commit: String = GH_91Tests.tip) -> RequirementPublicationRequest {
            RequirementPublicationRequest(
                requirement: root.id, branch: branch, commit: commit,
                verification: finalEvidence, proofs: proofs
            )
        }
    }

    static func policy(enabled: Bool) -> EffectivePolicy {
        var harness = HarnessSettings()
        harness.pullRequests = enabled
        return EffectivePolicy.resolve(harness: harness, repo: nil, defaultBranch: "main")
    }

    static func fixture(
        enabled: Bool = true, singleLeaf: Bool = false,
        lastLeafProven: Bool = true, githubTracker: Bool = true
    ) async throws -> Fixture {
        let ledger = try Ledger()
        let root = NodeSpec(
            id: "wn-GH-91", parent: nil, kind: singleLeaf ? .leaf : .composite,
            title: "Deliver verified checkout", intent: "Reject an order without a shipping address.",
            acceptanceCriteria: ["An address is required.", "An accepted order has a receipt."], touches: ["Checkout"]
        )
        let leaves = singleLeaf ? [] : [
            NodeSpec(
                id: "wn-GH-911", parent: root.id, kind: .leaf, title: "Validate address",
                intent: "Check the shipping address before accepting an order.",
                acceptanceCriteria: ["Missing addresses are rejected."], touches: ["Address"]
            ),
            NodeSpec(
                id: "wn-GH-912", parent: root.id, kind: .leaf, title: "Create receipt",
                intent: "Issue a receipt for accepted orders.",
                acceptanceCriteria: ["Accepted orders receive exactly one receipt."], touches: ["Receipt"]
            ),
        ]
        let all = [root] + leaves
        var proofs: [AcceptanceCriterionProof] = []
        var checks: [Evidence] = []
        for (index, node) in all.enumerated() {
            let ticket = index == 0 ? "GH-91" : "GH-\(910 + index)"
            try await ledger.append([
                LedgerEvent(node: node.id, by: .human("Reviewer"), kind: .nodeCreated(spec: node, ticket: ticket)),
            ])
            for (offset, _) in node.acceptanceCriteria.enumerated() {
                proofs.append(AcceptanceCriterionProof(
                    node: node.id, criterion: offset + 1, tests: ["\(node.testTarget).provesCriterion\(offset + 1)"]
                ))
            }
            let phase: Phase = !singleLeaf && index == 0 ? .split
                : (!lastLeafProven && index == all.count - 1 ? .ready : .proven)
            try await ledger.append([
                LedgerEvent(node: node.id, by: .reconciler, kind: .phaseChanged(to: phase)),
            ])
            if phase == .proven {
                try await ledger.append([
                    LedgerEvent(node: node.id, by: .reconciler, kind: .landed(commit: tip)),
                ])
                let evidence = Self.evidence(node, check: "\(node.testTarget) acceptance", summary: "\(node.title) passed")
                checks.append(evidence)
                try await Self.record(evidence, on: node.id, in: ledger)
            }
        }
        let final = [
            Self.evidence(root, check: "full test command", summary: "All checkout tests passed"),
            Self.evidence(root, check: "build application", summary: "Application build passed"),
        ]
        let tickets = all.enumerated().map { index, node in
            Ticket(
                key: index == 0 ? "GH-91" : "GH-\(910 + index)", title: node.title, description: node.intent,
                acceptanceCriteria: node.acceptanceCriteria, createdBy: .human("Reviewer")
            )
        }
        let local = LocalTracker(project: "GH", store: SeedTickets(tickets: tickets))
        let ordering = Ordering()
        return Fixture(
            ledger: ledger, root: root, leaves: leaves, proofs: proofs, leafEvidence: checks, finalEvidence: final,
            tracker: Tracker(local: local, isGitHub: githubTracker),
            github: GitHub(ordering: ordering), git: Git(ordering: ordering), enabled: enabled
        )
    }

    static func evidence(
        _ node: NodeSpec, check: String, passed: Bool = true, commit: String = tip,
        summary: String = "All checks passed", details: String? = nil
    ) -> Evidence {
        let file = check.replacingOccurrences(of: " ", with: "-") + (passed ? "-passed.log" : "-failed.log")
        return Evidence(
            check: check, passed: passed, summary: summary, specHash: node.specHash,
            builtBy: "implement-\(node.id)", checkedBy: "verify-\(node.id)",
            artifactPath: "local-artifacts/\(file)", artifactSHA256: Hashing.sha256(Data((check + summary).utf8)),
            commit: commit, details: details
        )
    }

    static func record(_ evidence: Evidence, on node: NodeID, in ledger: Ledger) async throws {
        try await ledger.append([
            LedgerEvent(node: node, by: .agent(run: evidence.checkedBy, role: .verifier), kind: .evidenceRecorded(evidence)),
        ])
    }

    static func replay(_ ledger: Ledger) async throws -> Ledger {
        let data = try JSONEncoder().encode(await ledger.allRecords())
        let records = try JSONDecoder().decode([RecordedEvent].self, from: data)
        let store = InMemoryLedgerStore()
        store.append(records)
        return try Ledger(store: store)
    }

    static func hasEvent(
        in ledger: Ledger, node: NodeID, values: [String] = [], containing fragments: [String] = []
    ) async throws -> Bool {
        for record in await ledger.records(for: node) {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record.event.kind))
            let fields = Self.jsonValues(object)
            if values.allSatisfy(fields.contains)
                && fragments.allSatisfy({ wanted in fields.contains { $0.contains(wanted) } }) { return true }
        }
        return false
    }

    private static func jsonValues(_ value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let number = value as? NSNumber { return [number.stringValue] }
        if let object = value as? [String: Any] { return object.values.flatMap(Self.jsonValues) }
        if let array = value as? [Any] { return array.flatMap(Self.jsonValues) }
        return []
    }

    static func single<Element>(_ values: [Element]) -> Element? { values.count == 1 ? values.first : nil }

    static func expectSafePush(_ arguments: [String], branch: String) throws {
        #expect(arguments.first == "push")
        #expect(!arguments.contains { $0.hasPrefix("--force") || ["-f", "--all", "--tags", "--mirror", "--delete"].contains($0) })
        #expect(!arguments.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("f") })
        #expect(!arguments.contains { $0.hasPrefix("+") })
        let remote = try #require(arguments.firstIndex(of: "origin"), "Only origin may be pushed.")
        let refspecs = arguments.dropFirst(remote + 1).filter { !$0.hasPrefix("-") }
        try #require(refspecs.count == 1, "Push exactly one explicit branch, not main, tags or all refs.")
        let parts = refspecs[refspecs.startIndex].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        #expect((1...2).contains(parts.count))
        for part in parts { #expect(part == branch || part == "refs/heads/\(branch)") }
    }

    private struct SeedTickets: TicketStore {
        let tickets: [Ticket]
        func load() throws -> [Ticket] { tickets }
        func save(_ tickets: [Ticket]) throws {}
    }

    struct Tracker: TrackerAdapter {
        let local: LocalTracker
        let isGitHub: Bool
        var contextRepository: String { isGitHub ? GH_91Tests.repository : "" }
        private var adapter: LocalTrackerAdapter { LocalTrackerAdapter(tracker: local) }
        func pendingSignals() async -> [Signal] { await adapter.pendingSignals() }
        func ticket(_ key: String) async -> Ticket? { await adapter.ticket(key) }
        func contextTickets() async -> [Ticket] { await adapter.contextTickets() }
        func consume(_ signal: Signal, reply: String) async { await adapter.consume(signal, reply: reply) }
        func createChildTicket(parent: String, spec: NodeSpec, by who: Participant) async throws -> String {
            await adapter.createChildTicket(parent: parent, spec: spec, by: who)
        }
        func comment(on key: String, _ text: String) async { await adapter.comment(on: key, text) }
        func setStatus(of key: String, to status: String) async { await adapter.setStatus(of: key, to: status) }
    }

    actor Ordering {
        var pushed = false
        var createAfterPush = false
        func push() { pushed = true }
        func create() { createAfterPush = pushed }
    }

    actor Git {
        let ordering: Ordering
        private var nextFailure = false
        private var tip = GH_91Tests.tip
        // Only pushes participate in publication assertions; inspection/fetch commands are separate.
        private(set) var commands: [[String]] = []
        private(set) var nonPushCommands: [[String]] = []
        var pushPrecededCreate: Bool { get async { await ordering.createAfterPush } }
        init(ordering: Ordering) { self.ordering = ordering }
        func setTip(_ value: String) { tip = value }
        func failNextPush() { nextFailure = true }
        func run(_ arguments: [String]) async throws -> String {
            guard arguments.first == "push" else {
                nonPushCommands.append(arguments)
                if arguments.first == "rev-parse" { return tip }
                if arguments.first == "ls-remote" {
                    let branch = arguments.last(where: { $0.hasPrefix("agentos/") || $0.hasPrefix("refs/heads/") })
                        ?? "agentos/GH-91"
                    let ref = branch.hasPrefix("refs/heads/") ? branch : "refs/heads/\(branch)"
                    return "\(tip)\t\(ref)\n"
                }
                return ""
            }
            commands.append(arguments)
            if nextFailure {
                nextFailure = false
                throw Failure(description: FailurePoint.push.message)
            }
            await ordering.push()
            return "Pushed \(tip)"
        }
    }

    actor GitHub: GitHubTransport {
        struct PR: Sendable {
            let number: Int
            let url: String
            let head: String
            let base: String
            var title: String
            var body: String
            var json: [String: Any] {
                [
                    "number": number, "html_url": url, "url": url, "state": "open", "merged": false,
                    "merged_at": NSNull(), "head": ["ref": head, "sha": GH_91Tests.tip],
                    "base": ["ref": base], "title": title, "body": body,
                ]
            }
        }
        private let ordering: Ordering
        private var failure: FailurePoint?
        private(set) var pullRequests: [PR] = []
        private(set) var mutations: [String] = []
        private(set) var operations: [String] = []
        private(set) var unexpectedRequests: [String] = []
        private(set) var createAttempts = 0
        private(set) var successfulCreates = 0
        private(set) var editedNumbers: [Int] = []

        init(ordering: Ordering) { self.ordering = ordering }
        func failNext(_ point: FailurePoint) { failure = point }
        func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
            let components = try #require(URLComponents(string: path))
            let resource = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let collection = "repos/\(GH_91Tests.repository)/pulls"
            if method == "GET", resource == collection {
                operations.append("list")
                let query = components.queryItems ?? []
                let head = query.first { $0.name == "head" }?.value?.split(separator: ":").last.map(String.init)
                let base = query.first { $0.name == "base" }?.value
                return try JSONSerialization.data(withJSONObject: pullRequests.filter {
                    (head == nil || $0.head == head) && (base == nil || $0.base == base)
                }.map(\.json))
            }
            if method == "GET", resource.hasPrefix(collection + "/"),
               let number = Int(resource.dropFirst(collection.count + 1)),
               let pr = pullRequests.first(where: { $0.number == number }) {
                operations.append("get")
                return try JSONSerialization.data(withJSONObject: pr.json)
            }
            if method == "POST", resource == collection {
                mutations.append("create")
                operations.append("create")
                createAttempts += 1
                if failure == .open {
                    failure = nil
                    throw Failure(description: FailurePoint.open.message)
                }
                let json = try Self.object(body)
                let number = 701 + successfulCreates
                let head = try #require(json["head"] as? String)
                let pr = PR(
                    number: number, url: "https://github.com/\(GH_91Tests.repository)/pull/\(number)",
                    head: try #require(head.split(separator: ":").last.map(String.init)),
                    base: try #require(json["base"] as? String),
                    title: try #require(json["title"] as? String), body: try #require(json["body"] as? String)
                )
                pullRequests.append(pr)
                successfulCreates += 1
                await ordering.create()
                if failure == .lostOpenResponse {
                    failure = nil
                    throw Failure(description: FailurePoint.lostOpenResponse.message)
                }
                return try JSONSerialization.data(withJSONObject: pr.json)
            }
            if method == "PATCH", resource.hasPrefix(collection + "/"),
               let number = Int(resource.dropFirst(collection.count + 1)),
               let index = pullRequests.firstIndex(where: { $0.number == number }) {
                mutations.append("update")
                operations.append("update")
                if failure == .update {
                    failure = nil
                    throw Failure(description: FailurePoint.update.message)
                }
                let json = try Self.object(body)
                if let title = json["title"] as? String { pullRequests[index].title = title }
                pullRequests[index].body = try #require(json["body"] as? String)
                editedNumbers.append(number)
                return try JSONSerialization.data(withJSONObject: pullRequests[index].json)
            }
            let message = "\(method) \(path)"
            unexpectedRequests.append(message)
            throw Failure(description: "Unexpected GitHub request (uploads and merges are forbidden): \(message)")
        }

        private static func object(_ data: Data?) throws -> [String: Any] {
            let data = try #require(data)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }
}
