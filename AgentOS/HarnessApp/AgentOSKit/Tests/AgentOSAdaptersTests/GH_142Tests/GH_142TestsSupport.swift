import AgentOSTestSupport
import Foundation
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

extension GH_142Tests {
    static var affectedTests: [String] {
        ["ZebraTests.keepsContract", "Tests/AlphaTests.swift"]
    }

    static var rootSpec: NodeSpec {
        NodeSpec(id: "wn-GH-142", kind: .composite, title: "Greeting features", intent: "Greet the user",
                 acceptanceCriteria: ["A greeting is stored", "A greeting is visible"])
    }

    static var ticket: Ticket {
        Ticket(key: "GH-142", title: Self.rootSpec.title, description: Self.rootSpec.intent,
               acceptanceCriteria: Self.rootSpec.acceptanceCriteria, createdBy: .human("Reviewer"))
    }

    static func proposal(_ title: String, tests: [String]?) -> ChildProposal {
        var child = ChildProposal(title: title, acceptanceCriteria: ["\(title) is available"], touches: ["Storage"],
                                  predictedPaths: ["Sources/Store.swift"])
        child.affectedTests = tests
        return child
    }

    static var children: [ChildProposal] {
        var display = Self.proposal("Show greeting", tests: ["DisplayTests.showsGreeting"])
        display.after = [1]
        return [
            Self.proposal("Store greeting", tests: Self.affectedTests),
            display,
            Self.proposal("Speak greeting", tests: nil),
            Self.proposal("Audit greeting", tests: []),
        ]
    }

    final class Fixture: Sendable {
        let ledger: Ledger
        let tracker = Tracker()
        let reconciler: Reconciler

        init(children: [ChildProposal]) throws {
            ledger = try Ledger()
            let services = Services()
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: services, workspace: services,
                artifacts: services, checks: services,
                team: AgentTeam(name: "GH-142", decomposer: Proposer(children: children),
                                testAuthor: services, implementer: services))
        }

        func preview() async throws -> String {
            await tracker.requestPreview()
            let report = try await withHangGuard("posting the breakdown preview") {
                await self.reconciler.runRound(waitForAgents: true)
            }
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
            return try #require(await tracker.comments.first { $0.contains("Preview #") })
        }

        func breakDown(commentContaining marker: String) async throws -> String {
            try await ledger.append([
                LedgerEvent(node: GH_142Tests.rootSpec.id, by: .human("Reviewer"),
                            kind: .nodeCreated(spec: GH_142Tests.rootSpec, ticket: GH_142Tests.ticket.key)),
                LedgerEvent(node: GH_142Tests.rootSpec.id, by: .human("Reviewer"), kind: .gateOpened(.breakdown)),
            ])
            let state = await ledger.workingState()
            let node = try #require(state.nodes[GH_142Tests.rootSpec.id])
            _ = try await withHangGuard("posting the completed breakdown") {
                try await self.reconciler.breakDown(node, in: state)
            }
            return try #require(await tracker.comments.first { $0.contains(marker) },
                                "The reconciler must post its \(marker) comment.")
        }
    }

    struct Proposer: Decomposer {
        let children: [ChildProposal]

        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            Breakdown(children: children)
        }
    }

    actor Tracker: TrackerAdapter {
        private var signals: [Signal] = []
        private(set) var comments: [String] = []
        private var childCount = 0

        func requestPreview() {
            signals.append(Signal(ticket: "GH-142", command: .preview, setBy: .human("Reviewer")))
        }
        func pendingSignals() -> [Signal] { signals }
        func ticket(_ key: String) -> Ticket? { key == "GH-142" ? GH_142Tests.ticket : nil }
        func consume(_ signal: Signal, reply: String) {
            signals.removeAll { $0.ticket == signal.ticket && $0.command == signal.command }
            comments.append(reply)
        }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) throws -> String {
            childCount += 1
            return "GH-142-child-\(childCount)"
        }
        func comment(on key: String, _ text: String) { comments.append(text) }
        func setStatus(of key: String, to status: String) {}
    }

    struct Services: Workspace, ExternalDependencySource, ArtifactStore, CheckRunner, TestAuthor, Implementer {
        func prepare() async throws {}
        func branch(for id: NodeID) -> String { "agentos/\(id)" }
        func worktree(for id: NodeID) -> URL {
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: id)
        }
        func createWorktree(for id: NodeID) async throws -> URL {
            throw AgentFailure("Breakdown comments do not need a worktree")
        }
        func removeWorktree(for id: NodeID) async throws {}
        func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
            throw AgentFailure("Unexpected commit in a breakdown comment test")
        }
        func head(of directory: URL) async throws -> String { throw AgentFailure("Unexpected HEAD read") }
        func changedFiles(in directory: URL) async throws -> [String] { [] }
        var testArea: String { "Tests/" }
        func testFolder(for spec: NodeSpec) -> String { "Tests/\(spec.testTarget)" }
        var agentContext: String { "" }
        func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult {
            throw AgentFailure("Unexpected rebase")
        }
        func abortRebase(_ directory: URL) async throws {}
        func resetForRework(_ directory: URL) async throws {}
        func landOnMain(_ id: NodeID) async throws -> String { throw AgentFailure("Unexpected landing") }
        func existingComponents() -> [String] { ["Storage", "Display"] }
        func prepareBuild(in directory: URL) async throws { throw AgentFailure("Unexpected build") }
        func deliveredKeys() async -> Set<String> { [] }
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            throw AgentFailure("Unexpected artifact")
        }
        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            Issue.record("Breakdown comment tests must not start checks")
            return CheckOutput(passed: false, summary: "Unexpected checks", log: "")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Unexpected test author")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Unexpected implementer")
        }
    }

    @MainActor
    static func detailImage(affectedTests: [String], kind: NodeKind = .leaf) async throws -> CGImage {
        var spec = Self.rootSpec
        spec.kind = kind
        spec.touches = ["Storage"]
        spec.predictedPaths = ["Sources/Store.swift", "Resources/Greetings"]
        spec.affectedTests = affectedTests
        let ledger = try Ledger()
        try await ledger.append([LedgerEvent(
            node: spec.id, by: .reconciler, kind: .nodeCreated(spec: spec, ticket: Self.ticket.key))])
        let model = HarnessViewModel()
        model.state = await ledger.workingState()
        let node = try #require(model.state.nodes[spec.id])
        let view = NodeDetail(node: node).environment(model)
            .frame(width: 750, height: 600).scaleEffect(2)
            .frame(width: 1500, height: 1200)
        return try RenderedUI.image(of: view, size: CGSize(width: 1500, height: 1200))
    }

    @MainActor
    static func rowImage(_ label: String, in image: CGImage) throws -> CGImage {
        let lines = try RenderedUI.lines(in: image)
        let labels = ["Ticket", "Phase", "Gates", "Links", "Touches", "Paths", "Affected tests", "Test target",
                      "Attempts failed", "Reworks", "Landed at", "Tests fingerprint", "Spec hash"]
        var boxes: [String: CGRect] = [:]
        for line in lines {
            for title in labels where line.text.range(of: title, options: [.anchored, .caseInsensitive]) != nil {
                boxes[title] = line.box
            }
        }
        let recognized = lines.map(\.text).joined(separator: "\n")
        let box = try #require(boxes[label], "Missing \(label) row in:\n\(recognized)")
        // Grid labels are centered vertically, including alongside multiline values.
        let top = boxes.values.filter { $0.minY > box.maxY }.map(\.minY).min() ?? 1
        let bottom = boxes.values.filter { $0.maxY < box.minY }.map(\.maxY).max() ?? 0
        let rect = CGRect(x: 0, y: (1 - top) * CGFloat(image.height),
                          width: CGFloat(image.width), height: (top - bottom) * CGFloat(image.height)).integral
        return try #require(image.cropping(to: rect))
    }

    @MainActor
    static func expectSeparateLines(_ entries: [String], in image: CGImage) throws {
        let lines = try RenderedUI.lines(in: image)
        let text = lines.map(\.text).joined(separator: "\n")
        let values = try entries.map { entry in
            try #require(lines.first { RenderedUI.shows(entry, in: $0.text) }, "Missing \(entry) in:\n\(text)")
        }
        for (index, line) in values.enumerated() {
            for other in values.dropFirst(index + 1) {
                #expect(line.box.minY >= other.box.maxY || other.box.minY >= line.box.maxY,
                        "Each entry must occupy its own line, not a comma-separated row:\n\(text)")
            }
        }
    }

    @MainActor
    static func expectDash(row label: String, in image: CGImage) throws {
        let row = try Self.rowImage(label, in: image)
        let lines = try RenderedUI.lines(in: row)
        let text = lines.map(\.text).joined(separator: "\n")
        if RenderedUI.shows("\(label) –", in: text) { return }
        let labelLine = try #require(lines.first { RenderedUI.shows(label, in: $0.text) },
                                     "Missing \(label) in:\n\(text)")
        #expect(lines.allSatisfy { RenderedUI.shows($0.text, in: label) },
                "The empty row must not contain a value other than a dash:\n\(text)")
        // Vision can omit a lone dash. Check for the short, flat mark beside the label in that case.
        let width = CGFloat(row.width), height = CGFloat(row.height)
        let labelHeight = labelLine.box.height * height
        let valueX = (labelLine.box.maxX * width).rounded(.up) + 8
        let area = CGRect(x: valueX, y: (1 - labelLine.box.maxY) * height,
                          width: width - valueX, height: labelHeight).integral
        let value = try #require(row.cropping(to: area))
        let mark = try #require(RenderedUI.inkRect(of: value), "Expected a dash, not a blank row:\n\(text)")
        #expect(mark.width > 1.5 * mark.height && mark.height < 0.5 * labelHeight,
                "The empty-value mark is not dash-shaped: \(mark.size)")
    }
}
