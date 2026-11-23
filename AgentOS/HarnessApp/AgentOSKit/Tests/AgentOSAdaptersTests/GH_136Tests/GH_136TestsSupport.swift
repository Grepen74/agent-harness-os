import AgentOSCore
import Foundation
import Testing

extension GH_136Tests {
    enum NodeShape: CaseIterable, Sendable {
        case rootComposite, nestedComposite, rootLeaf, childLeaf

        var isRoot: Bool { self == .rootComposite || self == .rootLeaf }
        var isLeaf: Bool { self == .rootLeaf || self == .childLeaf }
    }

    enum AreaEvidence: CaseIterable, Sendable {
        case touches, changedFile, nestedTouch

        var touches: [String] {
            switch self {
            case .touches: ["Payments"]
            case .changedFile: ["Docs"]
            case .nestedTouch: ["Payments/Storage"]
            }
        }
        var files: [String] { self == .changedFile ? ["Sources/Payments/Card.swift"] : [] }
    }

    enum HumanReviewSource: CaseIterable, Sendable {
        case overall, matchingTouch, matchingFile

        var overall: ReviewLevel { self == .overall ? .agentAndHuman : .agent }
        var areas: [String: ReviewLevel] {
            switch self {
            case .overall: [:]
            case .matchingTouch: ["Payments": .agentAndHuman]
            case .matchingFile: ["Payments": .agent, "Sources/Payments/*.swift": .agentAndHuman]
            }
        }
        var files: [String] { self == .matchingFile ? ["Sources/Payments/Card.swift"] : [] }
    }

    enum ReportContent: CaseIterable, Sendable {
        case assumption, question, both

        var assumptions: [String] { self == .question ? [] : ["Use the existing storage helper"] }
        var questions: [AgentQuestion] { self == .assumption ? [] : ["Which account should own the record?"] }
    }

    enum Stage {
        static let acceptanceTests = "acceptance-tests"
        static let acceptanceTestReview = "acceptance-test-review"
        static let changeReview = "change-review"
        static let landingQueue = "landing-queue"
        static let landingApproval = "landing-approval"
        static let batchChecks = "batch-checks"
        static let questions = "questions"
        static let buildGate = "build-gate"
        static let implementation = "implementation"
        static let proven = "proven"
        static let breakdown = "breakdown"
        static let children = "children"
        static let finalVerification = "final-verification"
        static let push = "push"
        static let pullRequest = "pull-request"
        static let manualMerge = "manual-merge"
    }

    static func policy(
        overall: ReviewLevel = .agent, areas: [String: ReviewLevel] = [:],
        guesswork: Guesswork = .assumeAndReport, publishing: Bool = false,
        repoPublishing: Bool? = nil, disabled: [HarnessCommand] = []
    ) -> EffectivePolicy {
        var harness = HarnessSettings()
        harness.review.level = overall
        harness.guesswork = guesswork
        harness.pullRequests = publishing
        let repo = RepoConfig(
            test: .init(command: "swift test"),
            signals: disabled.isEmpty ? nil : .init(disable: disabled.map(\.label)),
            review: .init(areas: areas.mapValues(\.rawValue)),
            pullRequests: repoPublishing)
        let effective = EffectivePolicy.resolve(harness: harness, repo: repo, defaultBranch: "main")
        #expect(effective.problems.isEmpty)
        #expect(effective.policy.review.level == overall)
        #expect(effective.policy.review.areas == areas)
        #expect(effective.policy.guesswork == guesswork)
        #expect(effective.policy.pullRequests == (publishing && repoPublishing != false))
        for command in disabled {
            #expect(!effective.policy.allowedSignals.contains(command))
        }
        return effective
    }

    static func node(
        shape: NodeShape = .childLeaf, touches: [String] = ["Docs"], files: [String] = [],
        assumptions: [String] = [], questions: [AgentQuestion] = [], go: Bool = false
    ) async throws -> NodeState {
        let ledger = try Ledger()
        let spec = NodeSpec(
            id: "wn-GH-136", parent: shape.isRoot ? nil : "wn-parent",
            kind: shape.isLeaf ? .leaf : .composite, title: "Project the process",
            intent: "Explain the applicable workflow", acceptanceCriteria: ["Show applicable stages"],
            touches: touches)
        func event(_ kind: EventKind, by: Participant = .reconciler) -> LedgerEvent {
            LedgerEvent(node: spec.id, by: by, kind: kind, at: Date(timeIntervalSince1970: 1_000))
        }
        var events: [LedgerEvent] = []
        if let parent = spec.parent {
            let root = NodeSpec(
                id: parent, parent: nil, kind: .composite, title: "Parent",
                intent: "Context", acceptanceCriteria: ["Children finish"])
            events.append(LedgerEvent(node: parent, by: .human("Alice"),
                                      kind: .nodeCreated(spec: root, ticket: "GH-parent")))
            events.append(LedgerEvent(node: parent, by: .reconciler, kind: .phaseChanged(to: .split)))
        }
        events += [
            event(.nodeCreated(spec: spec, ticket: "GH-136"), by: .human("Alice")),
            event(.gateOpened(.breakdown), by: .human("Alice")),
            event(.actualChangedFilesRecorded(files: files)),
            event(.assumptionsReported(role: .testAuthor, assumptions: assumptions)),
        ]
        if go {
            events += [
                event(.signalAccepted(ticket: "GH-136", command: .go, reply: "Started"), by: .human("Alice")),
                event(.gateOpened(.build), by: .human("Alice")),
            ]
        }
        if !questions.isEmpty {
            events += [
                event(.questionsRaised(role: .testAuthor, questions: questions)),
                event(.flagSet(.needsInput, reason: "Answer the test author's questions, then harness:retry")),
            ]
        }
        try await ledger.append(events)
        let state = await ledger.workingState()
        let node = try #require(state.nodes[spec.id])
        #expect(node.spec.touches == touches)
        #expect(node.actualChangedFiles == files)
        #expect(node.allAssumptions == assumptions)
        #expect(node.openQuestions == questions)
        #expect(state.hasGate(.build, at: node.id) == go)
        return node
    }

    static func project(_ policy: EffectivePolicy, node: NodeState? = nil) -> WorkflowProjection {
        WorkflowProjection.project(catalog: .standard, policy: policy, node: node)
    }

    static func stage(_ id: String, in projection: WorkflowProjection) throws -> WorkflowStage {
        try #require(projection.stages.first { $0.id == id }, "Expected applicable stage: \(id)")
    }

    static func signals(in projection: WorkflowProjection) -> Set<HarnessCommand> {
        projection.stages.reduce(into: Set<HarnessCommand>()) { $0.formUnion($1.signals) }
            .union(projection.transitions.flatMap(\.signals))
    }

    static func path(
        from source: String, to target: String, in projection: WorkflowProjection,
        avoiding: Set<String> = [], automatically: Bool = false
    ) -> Bool {
        let transitions = projection.transitions.filter { !automatically || $0.signals.isEmpty }
        let edges = Dictionary(grouping: transitions, by: \.source).mapValues { $0.map(\.target) }
        return Self.reaches(source, target, edges: edges, avoiding: avoiding)
    }

    static func reaches(
        _ source: String, _ target: String, edges: [String: [String]], avoiding: Set<String>
    ) -> Bool {
        var pending = [source]
        var visited = avoiding
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }
            if current == target { return true }
            pending.append(contentsOf: edges[current] ?? [])
        }
        return false
    }
}
