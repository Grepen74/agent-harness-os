import AgentOSCore
import AgentOSUI
import Foundation
import SwiftUI

extension GH_139Tests {
    static let root: NodeID = "wn-GH-139-parent"
    static let group: NodeID = "wn-GH-139-group"
    static let leaf: NodeID = "wn-GH-139-candidate"
    static let building: NodeID = "wn-GH-139-building"
    static let alsoBuilding: NodeID = "wn-GH-139-building-two"
    static let checking: NodeID = "wn-GH-139-checking"
    static let unrelated: NodeID = "wn-GH-139-unrelated"
    static let paneSize = CGSize(width: 1_500, height: 1_200)

    enum Recovery: String, CaseIterable, Sendable {
        case retry, replan, humanSpecified, questionsAnswered
    }

    static func spec(_ id: NodeID, parent: NodeID?, kind: NodeKind = .leaf, title: String) -> NodeSpec {
        NodeSpec(id: id, parent: parent, kind: kind, title: title,
                 intent: "Explain the current workflow without changing it",
                 acceptanceCriteria: ["Show where this node is"], touches: ["Weather"])
    }

    static func event(
        _ kind: EventKind, node: NodeID = leaf, by: Participant = .reconciler
    ) -> LedgerEvent {
        LedgerEvent(node: node, by: by, kind: kind, at: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func review(
        _ stage: ReviewStage, node: NodeID = leaf, passed: Bool = false, findings: [String] = []
    ) -> LedgerEvent {
        Self.event(.reviewRecorded(ReviewRecord(
            stage: stage, result: ReviewResult(passed: passed, findings: findings),
            commit: "candidate", uiEvidence: nil)), node: node)
    }

    static func otherStage(_ stage: ReviewStage) -> ReviewStage {
        stage == .acceptanceTests ? .change : .acceptanceTests
    }

    static func run(_ id: RunID, role: AgentRole) -> [LedgerEvent] {
        [Self.event(.runStarted(run: id, role: role)), Self.event(.runFinished(run: id, outcome: "completed"))]
    }

    static func reviewSetup(_ stage: ReviewStage) -> [LedgerEvent] {
        let parent = Self.spec(Self.root, parent: nil, kind: .composite, title: "Weather requirement")
        let candidate = Self.spec(Self.leaf, parent: Self.root, title: "Review candidate")
        return [
            Self.event(.nodeCreated(spec: parent, ticket: "GH-139-parent"), node: Self.root),
            Self.event(.gateOpened(.breakdown), node: Self.root, by: .human("Pat")),
            Self.event(.phaseChanged(to: .split), node: Self.root),
            Self.event(.nodeCreated(spec: candidate, ticket: "GH-139-candidate")),
            Self.event(.gateOpened(.build), by: .human("Pat")),
        ] + (stage == .change ? [
            Self.event(.testsFixed(digest: "acceptance-tests")),
            Self.event(.changeSubmitted(run: "implementation", commit: "candidate")),
            Self.event(.phaseChanged(to: .landing)),
        ] : [])
    }

    static func recoveryEvents(_ recovery: Recovery) -> [LedgerEvent] {
        switch recovery {
        case .retry:
            return [
                Self.event(.flagSet(.escalated, reason: "Review needs a person")),
                Self.event(.flagCleared(.escalated), by: .human("Pat")),
                Self.event(.attemptsReset, by: .human("Pat")),
                Self.event(.signalAccepted(ticket: "GH-139-candidate", command: .retry, reply: "attempts reset"),
                           by: .human("Pat")),
            ]
        case .replan:
            return [
                Self.event(.replanned(spec: Self.spec(Self.leaf, parent: Self.root, title: "Replanned candidate")),
                           by: .human("Pat")),
                Self.event(.signalAccepted(ticket: "GH-139-candidate", command: .replan, reply: "replanned"),
                           by: .human("Pat")),
            ]
        case .humanSpecified:
            return [Self.event(.phaseChanged(to: .specified), by: .human("Pat"))]
        case .questionsAnswered:
            return [
                Self.event(.questionsRaised(role: .testAuthor, questions: [AgentQuestion(question: "Which units?")])),
                Self.event(.flagSet(.needsInput, reason: "Which units?")),
                Self.event(.questionsAnswered(Clarification(questions: ["Which units?"], answer: "Celsius")),
                           by: .human("Pat")),
                Self.event(.flagCleared(.needsInput), by: .human("Pat")),
            ]
        }
    }

    static func treeEvents() -> [LedgerEvent] {
        let specs = [
            Self.spec(Self.root, parent: nil, kind: .composite, title: "Weather requirement"),
            Self.spec(Self.group, parent: Self.root, kind: .composite, title: "Forecast group"),
            Self.spec(Self.building, parent: Self.group, title: "First build"),
            Self.spec(Self.alsoBuilding, parent: Self.group, title: "Second build"),
            Self.spec(Self.checking, parent: Self.group, title: "Checking sibling"),
            Self.spec(Self.unrelated, parent: nil, kind: .composite, title: "Other work"),
        ]
        return specs.flatMap { spec -> [LedgerEvent] in
            var events = [Self.event(.nodeCreated(spec: spec, ticket: String(spec.id.dropFirst(3))), node: spec.id)]
            events.append(Self.event(.gateOpened(.build), node: spec.id, by: .human("Pat")))
            if spec.id == Self.root || spec.id == Self.group {
                events.append(Self.event(.phaseChanged(to: .split), node: spec.id))
            } else if spec.id == Self.building || spec.id == Self.alsoBuilding {
                events.append(Self.event(.testsFixed(digest: "tests-\(spec.id)"), node: spec.id))
                events.append(Self.event(.phaseChanged(to: .building), node: spec.id))
            } else if spec.id == Self.checking {
                events.append(Self.event(.testsFixed(digest: "tests-\(spec.id)"), node: spec.id))
                events.append(Self.event(.changeSubmitted(run: "checking-run", commit: "candidate"), node: spec.id))
                events.append(Self.event(.phaseChanged(to: .checking), node: spec.id))
            }
            return events
        }
    }

    static func model(_ ledger: Ledger, maxRounds: Int = 3) async -> HarnessViewModel {
        let model = HarnessViewModel()
        var settings = HarnessSettings()
        settings.maxAttempts = 9
        settings.maxReworks = 10
        settings.maxAgentRuns = 20
        var effective = EffectivePolicy.resolve(harness: settings, repo: nil, defaultBranch: "main")
        effective.policy.maxAttempts = 5
        effective.policy.maxReworks = 7
        effective.policy.maxAgentRuns = 11
        effective.policy.review.maxRounds = maxRounds
        model.policy = effective
        await Self.refresh(model, from: ledger)
        return model
    }

    static func refresh(_ model: HarnessViewModel, from ledger: Ledger) async {
        model.state = await ledger.workingState()
        await model.refreshHistory(from: ledger)
    }

    @MainActor final class RecordingActions: HarnessActions {
        var requests: [String] = []
        func stopRun(node: NodeID, run: RunID, by person: String) async { requests.append("stopRun") }
        func stopPreview(run: RunID, by person: String) async { requests.append("stopPreview") }
        func addLabel(_ name: String, to key: String) async { requests.append("addLabel") }
        func removeLabel(_ name: String, from key: String) async { requests.append("removeLabel") }
        func comment(_ text: String, on key: String) async { requests.append("comment") }
        func createTicket(title: String, description: String, criteria: [String], blockedBy: [String]) async {
            requests.append("createTicket")
        }
        func edit(_ key: String, title: String, description: String, criteria: [String], blockedBy: [String]) async {
            requests.append("edit")
        }
        func verifyChain() async { requests.append("verifyChain") }
        func tamperWithLedger() async { requests.append("tamperWithLedger") }
        func restoreLedger() async { requests.append("restoreLedger") }
        func runBaseline() async { requests.append("runBaseline") }
        func rescan() async { requests.append("rescan") }
        func open(_ path: String) { requests.append("open") }
        func openRepoConfig() { requests.append("openRepoConfig") }
    }
}
