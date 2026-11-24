// Expected API: AgentOSCore.WorkflowProjection.project(catalog:policy:node:) takes
// WorkflowCatalog, EffectivePolicy and NodeState? and returns stages and guarded transitions.
// Stages expose stable IDs, actors, opening signals, conditions and effective setting key/value pairs;
// transitions expose source/target IDs, opening signals and conditions. See .agentos-report.json.
// No source-only acceptance criteria: all six criteria have observable projection behaviour.
import AgentOSCore
import Testing

@Suite
struct GH_136Tests {
    @Test
    func projectionUsesTheSuppliedCatalogAndLeavesNoDanglingTransitions() throws {
        var catalog = WorkflowCatalog.standard
        #expect(catalog.stages.contains { $0.id == Stage.push })
        catalog.stages.removeAll { $0.id == Stage.push }
        catalog.transitions.removeAll { $0.source == Stage.push || $0.target == Stage.push }
        let projection = WorkflowProjection.project(
            catalog: catalog, policy: Self.policy(publishing: true), node: nil)

        _ = try Self.stage(Stage.implementation, in: projection)
        #expect(!projection.stages.contains { $0.id == Stage.push })
        let ids = Set(projection.stages.map(\.id))
        #expect(ids.isSubset(of: Set(catalog.stages.map(\.id))))
        #expect(!projection.transitions.isEmpty)
        for transition in projection.transitions {
            #expect(ids.contains(transition.source))
            #expect(ids.contains(transition.target))
            #expect(catalog.transitions.contains {
                $0.source == transition.source && $0.target == transition.target
            })
        }
    }

    @Test(arguments: NodeShape.allCases)
    func theNodeKindAndRootStatusSelectOnlyApplicableWorkflows(shape: NodeShape) async throws {
        let node = try await Self.node(shape: shape)
        let projection = Self.project(Self.policy(publishing: true), node: node)

        _ = try Self.stage(shape.isLeaf ? Stage.acceptanceTests : Stage.breakdown, in: projection)
        #expect(projection.stages.contains { $0.id == Stage.acceptanceTests } == shape.isLeaf)
        #expect(projection.stages.contains { $0.id == Stage.implementation } == shape.isLeaf)
        #expect(projection.stages.contains { $0.id == Stage.breakdown } == !shape.isLeaf)
        #expect(projection.stages.contains { $0.id == Stage.children } == !shape.isLeaf)
        for id in [Stage.finalVerification, Stage.push, Stage.pullRequest, Stage.manualMerge] {
            #expect(projection.stages.contains { $0.id == id } == shape.isRoot)
        }
        let ids = Set(projection.stages.map(\.id))
        #expect(projection.transitions.allSatisfy {
            ids.contains($0.source) && ids.contains($0.target)
        })
    }

    @Test
    func stagesExplainTheEffectiveSettingsThatShapeThem() throws {
        let policy = Self.policy(overall: .none, areas: ["Payments": .agent],
                                 guesswork: .ask, publishing: true)
        let projection = Self.project(policy)
        for id in [Stage.acceptanceTestReview, Stage.changeReview] {
            let stage = try Self.stage(id, in: projection)
            #expect(stage.settings["review.level"] == "none")
            #expect(stage.settings["review.areas.Payments"] == "agent")
            #expect(stage.actor == .reviewer)
        }
        #expect(try Self.stage(Stage.questions, in: projection)
            .settings["agents.guesswork"] == "ask")
        for id in [Stage.push, Stage.pullRequest] {
            #expect(try Self.stage(id, in: projection).settings["pullRequests"] == "true")
        }
        #expect(try Self.stage(Stage.acceptanceTests, in: projection).actor == .agent(.testAuthor))
    }

    @Test(arguments: AreaEvidence.allCases)
    func aMatchingAreaKeepsBothReviewsWhenOverallReviewIsNone(evidence: AreaEvidence) async throws {
        let node = try await Self.node(touches: evidence.touches, files: evidence.files)
        let projection = Self.project(Self.policy(overall: .none, areas: ["Payments": .agent]), node: node)

        for id in [Stage.acceptanceTestReview, Stage.changeReview] {
            _ = try Self.stage(id, in: projection)
        }
        #expect(Self.path(from: Stage.acceptanceTests, to: Stage.acceptanceTestReview, in: projection))
        #expect(Self.path(from: Stage.landingQueue, to: Stage.changeReview, in: projection))
    }

    @Test
    func anUnmatchedAreaDoesNotAddEitherReview() async throws {
        let node = try await Self.node(touches: ["PaymentsArchive"], files: ["Sources/Docs/Guide.swift"])
        let projection = Self.project(Self.policy(overall: .none, areas: ["Payments": .agent]), node: node)

        _ = try Self.stage(Stage.acceptanceTests, in: projection)
        _ = try Self.stage(Stage.implementation, in: projection)
        for id in [Stage.acceptanceTestReview, Stage.changeReview, Stage.landingApproval] {
            #expect(!projection.stages.contains { $0.id == id })
            #expect(!projection.transitions.contains { $0.source == id || $0.target == id })
        }
    }

    @Test
    func withoutANodeReviewGuardsNameEveryAreaRequiringReview() throws {
        let projection = Self.project(Self.policy(
            overall: .none, areas: ["Payments": .agent, "Authentication": .agentAndHuman, "Docs": .none]))
        for id in [Stage.acceptanceTestReview, Stage.changeReview] {
            let stage = try Self.stage(id, in: projection)
            #expect(stage.condition.contains("Payments"))
            #expect(stage.condition.contains("Authentication"))
        }

        let unreviewed = Self.project(Self.policy(overall: .none, areas: ["Docs": .none]))
        _ = try Self.stage(Stage.acceptanceTests, in: unreviewed)
        #expect(!unreviewed.stages.contains {
            $0.id == Stage.acceptanceTestReview || $0.id == Stage.changeReview
        })
    }

    @Test(arguments: [ReviewLevel.agent, .agentAndHuman])
    func withoutANodeTheOverallLevelAloneCanRequireBothReviews(level: ReviewLevel) throws {
        let projection = Self.project(Self.policy(overall: level))
        _ = try Self.stage(Stage.acceptanceTestReview, in: projection)
        _ = try Self.stage(Stage.changeReview, in: projection)
    }

    @Test(arguments: HumanReviewSource.allCases)
    func theStrictestReviewAddsPersonalBuildApprovalAndExcludesBatchedLanding(
        source: HumanReviewSource
    ) async throws {
        let node = try await Self.node(touches: ["Payments"], files: source.files)
        let projection = Self.project(Self.policy(overall: source.overall, areas: source.areas), node: node)
        let approval = try Self.stage(Stage.landingApproval, in: projection)

        #expect(approval.actor == .person)
        #expect(approval.signals.contains(.build))
        #expect(!approval.signals.contains(.go))
        #expect(Self.path(from: Stage.changeReview, to: Stage.landingApproval, in: projection))
        #expect(Self.path(from: Stage.landingApproval, to: Stage.proven, in: projection))
        #expect(!Self.path(from: Stage.landingQueue, to: Stage.proven, in: projection,
                          avoiding: [Stage.landingApproval]))
        #expect(!projection.stages.contains { $0.id == Stage.batchChecks })
        #expect(!projection.transitions.contains {
            $0.source == Stage.batchChecks || $0.target == Stage.batchChecks
        })
    }

    @Test
    func agentReviewKeepsTheBatchedLandingPathWithoutPersonalLandingApproval() async throws {
        let node = try await Self.node(touches: ["Payments"])
        let projection = Self.project(Self.policy(overall: .none, areas: ["Payments": .agent]), node: node)

        _ = try Self.stage(Stage.batchChecks, in: projection)
        #expect(!projection.stages.contains { $0.id == Stage.landingApproval })
        #expect(Self.path(from: Stage.landingQueue, to: Stage.changeReview, in: projection))
        #expect(Self.path(from: Stage.changeReview, to: Stage.batchChecks, in: projection))
        #expect(Self.path(from: Stage.batchChecks, to: Stage.proven, in: projection))
    }

    @Test(arguments: ReportContent.allCases)
    func askRoutesAnyAssumptionOrQuestionToTheQuestionsStop(report: ReportContent) async throws {
        let node = try await Self.node(assumptions: report.assumptions, questions: report.questions)
        let projection = Self.project(Self.policy(overall: .none, guesswork: .ask), node: node)

        _ = try Self.stage(Stage.questions, in: projection)
        #expect(Self.path(from: Stage.acceptanceTests, to: Stage.questions, in: projection,
                          avoiding: [Stage.buildGate, Stage.implementation], automatically: true))
        #expect(!Self.path(from: Stage.acceptanceTests, to: Stage.implementation, in: projection,
                          avoiding: [Stage.questions], automatically: true))
        #expect(!Self.path(from: Stage.acceptanceTests, to: Stage.buildGate, in: projection,
                          avoiding: [Stage.questions], automatically: true))
    }

    @Test
    func askWithACleanReportReachesTheBuildGateInsteadOfQuestions() async throws {
        let node = try await Self.node()
        let projection = Self.project(Self.policy(overall: .none, guesswork: .ask), node: node)
        let gate = try Self.stage(Stage.buildGate, in: projection)

        #expect(gate.actor == .person)
        #expect(gate.signals.contains(.build))
        #expect(Self.path(from: Stage.acceptanceTests, to: Stage.buildGate, in: projection,
                          avoiding: [Stage.questions, Stage.implementation], automatically: true))
        #expect(!Self.path(from: Stage.acceptanceTests, to: Stage.questions, in: projection,
                          avoiding: [Stage.implementation], automatically: true))
    }

    @Test
    func assumeAndReportStillWaitsForBuildApprovalAfterAssumptionsEvenUnderGo() async throws {
        let node = try await Self.node(assumptions: ["Use the existing storage helper"], go: true)
        let projection = Self.project(Self.policy(overall: .none, guesswork: .assumeAndReport), node: node)
        let gate = try Self.stage(Stage.buildGate, in: projection)

        #expect(gate.actor == .person)
        #expect(gate.signals.contains(.build))
        #expect(!gate.signals.contains(.go))
        #expect(gate.settings["agents.guesswork"] == "assume-and-report")
        #expect(Self.path(from: Stage.acceptanceTests, to: Stage.buildGate, in: projection,
                          avoiding: [Stage.questions, Stage.implementation], automatically: true))
        #expect(!Self.path(from: Stage.acceptanceTests, to: Stage.implementation, in: projection,
                          avoiding: [Stage.buildGate], automatically: true))
        let approvals = projection.transitions.filter {
            $0.source == Stage.buildGate && $0.signals.contains(.build)
        }
        #expect(!approvals.isEmpty)
        #expect(approvals.allSatisfy { !$0.signals.contains(.go) })
    }

    @Test
    func assumeAndReportWithACleanGoRunContinuesWithoutAnApprovalStop() async throws {
        let node = try await Self.node(go: true)
        let projection = Self.project(Self.policy(overall: .none, guesswork: .assumeAndReport), node: node)

        _ = try Self.stage(Stage.acceptanceTests, in: projection)
        _ = try Self.stage(Stage.implementation, in: projection)
        #expect(Self.path(from: Stage.acceptanceTests, to: Stage.implementation, in: projection,
                          avoiding: [Stage.buildGate, Stage.questions], automatically: true))
        for stop in [Stage.buildGate, Stage.questions] {
            #expect(!Self.path(from: Stage.acceptanceTests, to: stop, in: projection,
                              avoiding: [Stage.implementation], automatically: true))
        }
    }

    @Test(arguments: [HarnessCommand.build, .go, .breakdown, .retry])
    func aRepoDisabledSignalDisappearsFromEveryGateAndTransition(command: HarnessCommand) throws {
        let enabled = Self.project(Self.policy(overall: .agentAndHuman, guesswork: .ask, publishing: true))
        let baselineSignals = Self.signals(in: enabled)
        #expect(baselineSignals.contains(command), "Check the enabled path before asserting its removal.")
        let disabled = Self.project(Self.policy(
            overall: .agentAndHuman, guesswork: .ask, publishing: true, disabled: [command]))

        _ = try Self.stage(Stage.acceptanceTests, in: disabled)
        #expect(disabled.stages.allSatisfy { !$0.signals.contains(command) })
        #expect(disabled.transitions.allSatisfy { !$0.signals.contains(command) })
        #expect(Self.signals(in: disabled).isSuperset(of: baselineSignals.subtracting([command])))
    }

    @Test(arguments: [NodeShape.rootComposite, .rootLeaf])
    func publishingOffKeepsFinalVerificationAndManualMergeWithoutPushOrPullRequest(
        shape: NodeShape
    ) async throws {
        let node = try await Self.node(shape: shape)
        let enabled = Self.project(Self.policy(publishing: true), node: node)
        _ = try Self.stage(Stage.push, in: enabled)
        _ = try Self.stage(Stage.pullRequest, in: enabled)
        let disabled = Self.project(Self.policy(publishing: true, repoPublishing: false), node: node)

        _ = try Self.stage(Stage.finalVerification, in: disabled)
        #expect(try Self.stage(Stage.manualMerge, in: disabled).actor == .person)
        for id in [Stage.push, Stage.pullRequest] {
            #expect(!disabled.stages.contains { $0.id == id })
            #expect(!disabled.transitions.contains { $0.source == id || $0.target == id })
        }
        #expect(Self.path(from: Stage.finalVerification, to: Stage.manualMerge, in: disabled,
                          avoiding: [Stage.push, Stage.pullRequest]))
    }

    @Test
    func graphAssertionsHandleCyclesDirectionAndBlockedCheckpoints() {
        let edges = ["tests": ["compile"], "compile": ["tests", "approval"], "approval": ["build"]]
        #expect(Self.reaches("tests", "build", edges: edges, avoiding: []))
        #expect(!Self.reaches("build", "tests", edges: edges, avoiding: []))
        #expect(!Self.reaches("tests", "build", edges: edges, avoiding: ["approval"]))
        #expect(!Self.reaches("tests", "missing", edges: edges, avoiding: []))
    }
}
