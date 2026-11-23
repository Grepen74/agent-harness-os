import AgentOSAdapters
import AgentOSTestSupport
import Foundation
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

extension GH_143Tests {
    static let rootID = "wn-GH-143"
    static let ticket = Ticket(
        key: "GH-143", title: "Revise billing", description: "Change billing contracts",
        acceptanceCriteria: ["Currency is rounded", "Receipts show the new layout"],
        createdBy: .human("Ticket writer"))

    static func child(_ title: String, affected: [String]?) -> ChildProposal {
        var proposal = ChildProposal(title: title, acceptanceCriteria: ["\(title) is visible"], touches: ["Billing"])
        proposal.affectedTests = affected
        return proposal
    }

    static func children() -> [ChildProposal] {
        [
            child("Change currency rounding", affected: [
                "MoneyTests.roundsAmounts", "Tests/Legacy/TaxTests.swift",
            ]),
            child("Change receipt layout", affected: ["Tests/Legacy/ReceiptTests.swift"]),
            child("Add a billing hint", affected: nil),
            child("Add a receipt footer", affected: []),
        ]
    }

    struct Approval {
        let node: NodeID?
        let by: Participant
        let files: [String]
    }

    static func singleApproval(_ approvals: [Approval]) -> Approval? {
        approvals.count == 1 ? approvals.first : nil
    }

    static func approvals(in records: [RecordedEvent]) -> [Approval] {
        records.compactMap {
            guard case .testUpdatesApproved(let files) = $0.event.kind else { return nil }
            return Approval(node: $0.event.node, by: $0.event.by, files: files)
        }
    }

    static func section(for title: String, in comment: String, children: [ChildProposal]) throws -> String {
        let start = try #require(comment.range(of: title)?.lowerBound, "Missing child \(title): \(comment)")
        let remainder = comment[start...]
        let end = children.filter { $0.title != title }.compactMap {
            remainder.range(of: $0.title)?.lowerBound
        }.min() ?? comment.endIndex
        return String(comment[start..<end])
    }

    @MainActor
    static func ledgerText(_ event: LedgerEvent) async throws -> String {
        let ledger = try Ledger()
        try await ledger.append([event])
        let model = HarnessViewModel()
        await model.refreshLedger(from: ledger)
        return try RenderedUI.text(
            of: LedgerPane().environment(model), size: CGSize(width: 2000, height: 900))
    }

    final class Fixture: Sendable {
        let directory: URL
        let store: FileLedgerStore
        let ledger: Ledger
        let tracker = Tracker()
        let proposer: Proposer
        let reconciler: Reconciler
        let children: [ChildProposal]

        init(children: [ChildProposal]) throws {
            directory = FileManager.default.temporaryDirectory.appending(
                path: "GH_143Tests-\(UUID().uuidString)",
                directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = FileLedgerStore(fileURL: directory.appending(path: "ledger.jsonl"))
            ledger = try Ledger(store: store)
            self.children = children
            proposer = Proposer(children: children)
            let services = Services(directory: directory)
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: services, workspace: services,
                artifacts: services, checks: services,
                team: AgentTeam(name: "GH-143", decomposer: proposer,
                                testAuthor: services, implementer: services))
            try writeTest("Tests/Legacy/MoneyTests.swift", suite: "MoneyTests", test: "roundsAmounts")
            try writeTest("Tests/Legacy/TaxTests.swift", suite: "TaxTests", test: "roundsTax")
            try writeTest("Tests/Legacy/ReceiptTests.swift", suite: "ReceiptTests", test: "showsReceipt")
        }

        func cleanUp() {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Could not remove this test's scratch directory: \(error)") }
        }

        func writeTest(_ path: String, suite: String, test: String) throws {
            let file = directory.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try """
                import Testing
                @Suite struct \(suite) {
                    @Test func \(test)() { #expect(true) }
                }
                """.write(to: file, atomically: true, encoding: .utf8)
        }

        func adopt() async throws {
            try await ledger.append([
                LedgerEvent(node: GH_143Tests.rootID, by: .human("Ticket adopter"),
                            kind: .nodeCreated(spec: Planner.rootSpec(for: GH_143Tests.ticket), ticket: "GH-143")),
            ])
        }

        func showPreview(specHash: String? = nil) async throws {
            let root = Planner.rootSpec(for: GH_143Tests.ticket)
            let specs = Planner.childSpecs(parent: root, proposals: children)
            try await ledger.append([
                LedgerEvent(node: nil, by: .reconciler, kind: .previewRecorded(
                    ticket: "GH-143", number: 1, specHash: specHash ?? root.specHash, proposal: specs)),
            ])
        }

        func signal(_ command: HarnessCommand, by person: String) async throws {
            await tracker.request(command, by: person)
            var report = RoundReport()
            await reconciler.intakeSignals(&report, waitingForPreviews: true)
            let records = await ledger.allRecords()
            #expect(records.contains {
                if case .signalAccepted(let ticket, let accepted, _) = $0.event.kind {
                    return ticket == "GH-143" && accepted == command
                }
                return false
            }, "The fixture's human signal must be accepted: \(report.actions)")
            _ = try #require(await ledger.workingState().nodes[GH_143Tests.rootID])
        }

        func breakDown() async throws {
            try await withHangGuard("GH-143 breakdown") {
                let state = await self.ledger.workingState()
                let node = try #require(state.nodes[GH_143Tests.rootID])
                _ = try await self.reconciler.breakDown(node, in: state)
            }
        }

        func breakdownComment() async throws -> String {
            try #require(await tracker.comments.first {
                $0.contains("Broken down") || $0.contains("leaf check passed")
            })
        }
    }

    actor Proposer: Decomposer {
        var children: [ChildProposal]
        private(set) var calls = 0
        init(children: [ChildProposal]) { self.children = children }
        func replace(_ children: [ChildProposal]) { self.children = children }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            calls += 1
            return Breakdown(children: children)
        }
    }

    actor Tracker: TrackerAdapter {
        private var signals: [Signal] = []
        private(set) var comments: [String] = []
        private(set) var created: [NodeSpec] = []
        func request(_ command: HarnessCommand, by person: String) {
            signals.append(Signal(ticket: "GH-143", command: command, setBy: .human(person)))
        }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? { key == "GH-143" ? GH_143Tests.ticket : nil }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            comments.append(reply)
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) -> String {
            created.append(spec)
            return "GH-\(900 + created.count)"
        }
        func comment(on key: String, _ text: String) { comments.append(text) }
        func setStatus(of key: String, to status: String) {}
    }

    struct Services: Workspace, ExternalDependencySource, ArtifactStore, CheckRunner, TestAuthor, Implementer {
        let directory: URL
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL { directory }
        func createWorktree(for id: NodeID) async throws -> URL { throw AgentFailure("Unexpected test author") }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Unexpected commit in a breakdown test")
        }
        func head(of directory: URL) async throws -> String { "fixture-head" }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { .clean }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { throw AgentFailure("Unexpected landing") }
        func existingComponents() -> [String] { ["Billing"] }
        func prepareBuild(in directory: URL) async throws { throw AgentFailure("Unexpected build") }
        func createSnapshot() async throws -> URL? { directory }
        func removeSnapshot(_ directory: URL) async {}
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            throw AgentFailure("Unexpected artifact")
        }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("A breakdown test must not run build checks")
            return CheckOutput(passed: false, summary: "Unexpected checks", log: "")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Unexpected test author")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport { throw AgentFailure("Unexpected implementer") }
    }

    static func legacyRecords() throws -> [RecordedEvent] {
        let events = """
            [
              {"id":"00000000-0000-0000-0000-000000000143","node":"wn-GH-143",
               "by":{"human":{"_0":"Morgan"}},"at":"2025-01-01T00:00:00Z",
               "kind":{"nodeCreated":{"ticket":"GH-143","spec":{
                 "id":"wn-GH-143","kind":"composite","title":"Revise billing","intent":"Change billing contracts",
                 "acceptanceCriteria":["Currency is rounded"],"touches":[],"dependsOn":[],"profile":"simple-app"}}}},
              {"id":"00000000-0000-0000-0000-000000000144","node":"wn-GH-143",
               "by":{"human":{"_0":"Morgan"}},"at":"2025-01-01T00:00:01Z",
               "kind":{"gateOpened":{"_0":"breakdown"}}},
              {"id":"00000000-0000-0000-0000-000000000145","node":"wn-GH-143",
               "by":{"reconciler":{}},"at":"2025-01-01T00:00:02Z",
               "kind":{"becameLeaf":{"touches":["Billing"]}}}
            ]
            """
        let objects = try #require(JSONSerialization.jsonObject(with: Data(events.utf8)) as? [[String: Any]])
        var previousHash = RecordedEvent.genesisHash
        return try objects.enumerated().map { position, event in
            var payload: [String: Any] = ["position": position, "previousHash": previousHash, "event": event]
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            previousHash = Hashing.sha256(bytes)
            payload["hash"] = previousHash
            return try Hashing.decoder().decode(RecordedEvent.self, from: JSONSerialization.data(withJSONObject: payload))
        }
    }
}
