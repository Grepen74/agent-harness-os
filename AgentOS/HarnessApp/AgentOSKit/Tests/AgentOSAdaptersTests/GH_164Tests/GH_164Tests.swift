// Expected API: ChildProposal.integration: Bool? and NodeSpec.integration: Bool (default false).
// Existing CopilotDecomposer.parse/prompt, Planner.childSpecs/describe, NodeSpec.specHash/Codable,
// and Ledger replay/verification expose the behaviour; no new planner or parser entry point is needed.
// Prompt requirements (AC2 and AC3) are checked through prompt(for:), not by reading source files.
// Reviewer-only part of AC5: the frozen pre-integration ledger fixture is checked into this test folder.
import Foundation
import Testing
@testable import AgentOSAdapters
@testable import AgentOSCore

@Suite struct GH_164Tests {
    @Test(arguments: [false, true])
    func decomposerRepliesKeepTrueAndTreatFalseOrMissingAsOrdinary(bareArray: Bool) throws {
        let children = """
        [
          {"title":"Save greeting","acceptanceCriteria":["A greeting is stored"],"integration":false},
          {"title":"Display greeting","acceptanceCriteria":["A stored greeting is visible"]},
          {"title":"Combined workflow","acceptanceCriteria":["A saved greeting reaches the display"],
           "touches":["Workflow"],"predictedPaths":["Sources/Workflow"],"integration":true}
        ]
        """
        let reply = bareArray ? children : #"{"questions":[],"assumptions":[],"children":\#(children)}"#
        let breakdown = try #require(CopilotDecomposer.parse(reply))
        try #require(breakdown.children.count == 3)

        #expect(breakdown.children[0].integration != true)
        #expect(breakdown.children[1].integration != true)
        #expect(breakdown.children[2].integration == true)
        #expect(breakdown.children[2].title == "Combined workflow")
        #expect(breakdown.children[2].acceptanceCriteria == ["A saved greeting reaches the display"])
        #expect(breakdown.children[2].touches == ["Workflow"])
        #expect(breakdown.children[2].predictedPaths == ["Sources/Workflow"])
    }

    @Test func decomposerJSONFormatIncludesIntegrationOnTheChild() throws {
        let prompt = Self.decomposerInstructions()
        try #require(Self.matches(prompt, #"(?s)"children"\s*:\s*\[\s*\{[^}]*"affectedTests"\s*:"#),
                     "Validate the prompt extraction and matching helpers against the existing child format.")
        #expect(Self.matches(prompt, #"(?s)"children"\s*:\s*\[\s*\{[^}]*"integration"\s*:"#),
                "The reply format must list integration inside the child object.")
    }

    @Test func decomposerLimitsIntegrationToOneLastChildForCombinedObservations() {
        let prompt = Self.decomposerInstructions()
        #expect(Self.matches(
            prompt, #"(at most|no more than|up to|only) (one|1|a single) integration (child|item)"#
        ), "The decomposer must add at most one integration child.")
        #expect(Self.matches(
            prompt, #"integration (child|item)[^.]*\blast\b|\blast\b[^.]*integration (child|item)"#
        ), "The integration child must be last.")
        #expect(Self.matches(
            prompt, #"integration[^.]*only (when|if)|only (when|if)[^.]*integration"#
        ), "Adding an integration child must be conditional, not mandatory for every breakdown.")
        #expect(Self.matches(
            prompt, #"parent[^.]*criteri[^.]*observ|observ[^.]*parent[^.]*criteri"#
        ), "The condition must concern observable parent criteria.")
        #expect(Self.matches(
            prompt, #"(two or more|2 or more|at least two|at least 2|multiple) children[^.]*(together|combin|interact)"#
        ), "The observations must require two or more children working together.")
    }

    @Test func integrationPromptRequiresFullCombinedCriteriaAndPlausibleSeamPaths() {
        let prompt = Self.decomposerInstructions()
        #expect(Self.matches(
            prompt, #"(combined|joint|end-to-end)[^.]*observ[^.]*(in full|fully|complete)|criteri[^.]*(in full|fully|complete)[^.]*(combined|joint|end-to-end)"#
        ), "Integration criteria must state the combined observations in full.")
        #expect(Self.matches(
            prompt, #"(without repeating|do not repeat|don't repeat|must not repeat|not repeat|no repetition)[^.]*(ordinary|other|sibling|non-integration)[^.]*criteri"#
        ), "Integration criteria must not repeat the ordinary children's criteria.")
        #expect(Self.matches(
            prompt, #"predictedpaths[^.]*seam[^.]*(fix|repair)|seam[^.]*(fix|repair)[^.]*predictedpaths"#
        ), "The integration child's own predictedPaths must cover plausible seam fixes.")
        #expect(Self.matches(
            prompt, #"predictedpaths[^.]*(plausible|likely|possible)[^.]*seam|(plausible|likely|possible)[^.]*seam[^.]*predictedpaths"#
        ), "The path predictions must anticipate plausible seam changes, not just list test files.")
    }

    @Test func decomposerRequiresParentCoverageWithOneOwnerPerAtomicRuleAndDistinctRefinements() {
        let prompt = Self.decomposerInstructions()
        #expect(Self.matches(
            prompt, #"(every|each|all) parent (criterion|criteria)[^.]*(account|cover|represent|child criteria)|child criteria[^.]*(account|cover|represent)[^.]*(every|each|all) parent"#
        ), "Every parent criterion must be accounted for by child criteria.")
        #expect(Self.matches(
            prompt, #"(each|every) (atomic )?rule[^.]*(one (owner|child)|single (owner|child))"#
        ), "Each atomic rule must have one owning child.")
        #expect(Self.matches(
            prompt, #"(several|multiple|more than one|different|distinct)[^.]*refinement[^.]*(same|one|single) parent criterion"#
        ), "Distinct refinements may contribute to the same parent criterion.")
    }

    @Test(arguments: [false, true])
    func plannerWidensOnlyIntegrationTouchesAndKeepsEachChildsOwnPaths(hasSeamPaths: Bool) throws {
        let proposals = Self.proposals(hasSeamPaths: hasSeamPaths)
        let specs = Planner.childSpecs(parent: Self.parent(), proposals: proposals)
        try #require(specs.count == 3)

        #expect(!specs[0].integration)
        #expect(!specs[1].integration)
        #expect(specs[2].integration)
        #expect(specs[0].touches == ["Shared", "Storage"])
        #expect(specs[1].touches == ["Presentation", "Shared"])
        let union: Set<String> = ["Presentation", "Shared", "Storage", "Workflow"]
        #expect(Set(specs[2].touches) == union)
        #expect(specs[2].touches.count == union.count, "Shared components occur only once in the union.")
        #expect(specs[0].predictedPaths == ["Sources/Storage/Writer.swift"])
        #expect(specs[1].predictedPaths == ["Sources/Presentation"])
        #expect(specs[2].predictedPaths == (proposals[2].predictedPaths ?? []),
                "Sibling paths must not be inherited, even when the integration proposal predicts no paths.")
        #expect(specs[2].acceptanceCriteria == proposals[2].acceptanceCriteria)
    }

    @Test func integrationMarkStaysOnNodeAndPreviewSpecsAfterLedgerReload() async throws {
        let parent = Self.parent()
        let specs = Planner.childSpecs(parent: parent, proposals: Self.proposals(hasSeamPaths: true))
        try #require(specs.count == 3)
        let ledger = try Ledger()
        try await ledger.append([
            LedgerEvent(node: parent.id, by: .human("Reviewer"),
                        kind: .nodeCreated(spec: parent, ticket: "GH-164"))
        ] + specs.enumerated().map { index, spec in
            LedgerEvent(node: spec.id, by: .reconciler,
                        kind: .nodeCreated(spec: spec, ticket: "GH-164-child-\(index + 1)"))
        } + [
            LedgerEvent(node: nil, by: .reconciler,
                        kind: .previewRecorded(ticket: "GH-164-preview", number: 1,
                                               specHash: parent.specHash, proposal: specs))
        ])

        let store = InMemoryLedgerStore()
        store.append(try Hashing.decoder().decode(
            [RecordedEvent].self, from: Hashing.canonicalJSON(await ledger.allRecords())))
        let reopened = try Ledger(store: store)
        #expect(await reopened.verifyChain().isIntact)
        let state = await reopened.workingState()
        let preview = try #require(state.previews["GH-164-preview"])
        try #require(preview.proposal.count == 3)
        for (index, spec) in specs.enumerated() {
            let saved = try #require(state.nodes[spec.id])
            #expect(saved.spec.integration == (index == 2))
            #expect(preview.proposal[index].integration == (index == 2))
            #expect(saved.spec.touches == spec.touches)
            #expect(saved.spec.predictedPaths == spec.predictedPaths)
            #expect(saved.spec.specHash == spec.specHash)
        }
    }

    @Test(arguments: [false, true])
    func falseAndAbsentMarksHaveIdenticalCanonicalJSONAndNoIntegrationKey(withAffectedTests: Bool) throws {
        var original = Self.parent()
        original.kind = .leaf
        original.predictedPaths = ["Sources/Storage"]
        original.after = ["earlier-spec"]
        original.affectedTests = withAffectedTests ? ["StorageTests.savesGreeting"] : []
        let absentJSON = Hashing.canonicalJSON(original)
        var falseObject = try Self.object(absentJSON)
        falseObject["integration"] = false
        let decodedFalse = try Hashing.decoder().decode(
            NodeSpec.self, from: JSONSerialization.data(withJSONObject: falseObject))
        let decodedAbsent = try Hashing.decoder().decode(NodeSpec.self, from: absentJSON)
        var explicitlyFalse = original
        explicitlyFalse.integration = false

        #expect(!decodedFalse.integration)
        #expect(!decodedAbsent.integration)
        #expect(Hashing.canonicalJSON(decodedFalse) == absentJSON)
        #expect(Hashing.canonicalJSON(decodedAbsent) == absentJSON)
        #expect(Hashing.canonicalJSON(explicitlyFalse) == absentJSON)
        #expect(try Self.object(Hashing.canonicalJSON(decodedFalse))["integration"] == nil)
        #expect(try Self.object(absentJSON)["integration"] == nil)
        #expect(decodedFalse.specHash == decodedAbsent.specHash)
        #expect(explicitlyFalse.specHash == decodedAbsent.specHash)
    }

    @Test func preIntegrationLedgerReplaysAndEveryRecordedSpecHashStillMatches() async throws {
        let records = try Self.legacyLedger.split(separator: "\n").map {
            try Hashing.decoder().decode(RecordedEvent.self, from: Data($0.utf8))
        }
        let store = InMemoryLedgerStore()
        store.append(records)
        let ledger = try Ledger(store: store)
        let chain = await ledger.verifyChain()
        #expect(chain.isIntact, "\(chain.problem?.reason ?? "")")
        #expect(chain.checked == records.count)
        let state = await ledger.workingState()
        #expect(Set(state.nodes.keys) == Set([
            "wn-GH-164-legacy", "wn-GH-164-legacy.1", "wn-GH-164-legacy.2"
        ]))
        let parent = try #require(state.nodes["wn-GH-164-legacy"])
        #expect(parent.phase == .split)
        #expect(parent.children == ["wn-GH-164-legacy.1", "wn-GH-164-legacy.2"])
        for node in state.nodes.values {
            #expect(!node.spec.integration)
            let evidence = try #require(node.evidence.first,
                                        "Each fixture node has its pre-integration fingerprint recorded as evidence.")
            #expect(node.spec.specHash == evidence.specHash, "Legacy fingerprint changed for \(node.id).")
            #expect(try Self.object(Hashing.canonicalJSON(node.spec))["integration"] == nil)
        }
        let encoded = Hashing.canonicalJSON(await ledger.allRecords())
        let reencodedStore = InMemoryLedgerStore()
        reencodedStore.append(try Hashing.decoder().decode([RecordedEvent].self, from: encoded))
        #expect(await (try Ledger(store: reencodedStore)).verifyChain().isIntact)
    }

    @Test(arguments: [false, true])
    func markingTheSameSpecIntegrationChangesItsHashAndSurvivesCodable(withAffectedTests: Bool) throws {
        var ordinary = Self.parent()
        ordinary.kind = .leaf
        ordinary.affectedTests = withAffectedTests ? ["WorkflowTests.savedGreetingIsShown"] : []
        var integration = ordinary
        integration.integration = true

        #expect(integration.specHash != ordinary.specHash,
                "Changing only the integration mark must invalidate the earlier spec fingerprint.")
        let data = Hashing.canonicalJSON(integration)
        #expect(try Self.object(data)["integration"] as? Bool == true)
        let restored = try Hashing.decoder().decode(NodeSpec.self, from: data)
        #expect(restored.integration)
        #expect(restored.specHash == integration.specHash)
        integration.integration = false
        #expect(integration.specHash == ordinary.specHash)
    }

    @Test(arguments: [false, true])
    func previewLabelsOnlyTheIntegrationChildAndExplainsItsSiblingWait(hasExplicitAfter: Bool) throws {
        var proposals = Self.proposals(hasSeamPaths: true)
        proposals[1].after = [1]
        proposals[2].after = hasExplicitAfter ? [1] : nil
        let specs = Planner.childSpecs(parent: Self.parent(), proposals: proposals)
        let description = Planner.describe(specs, under: "Greeting workflow")
        let lines = description.components(separatedBy: "\n")
        let integrationLine = try #require(lines.first { $0.contains("Combined workflow") })
        #expect(integrationLine.contains("integration tests"))
        #expect(integrationLine.contains("waiting for all other children"),
                "The explanation must describe all siblings, not only the proposal's explicit after list.")
        for title in ["Save greeting", "Display greeting"] {
            let ordinaryLine = try #require(lines.first { $0.contains(title) })
            #expect(!ordinaryLine.contains("integration tests"))
            #expect(!ordinaryLine.contains("waiting for all other children"))
        }
    }
}

private extension GH_164Tests {
    static func parent() -> NodeSpec {
        NodeSpec(id: "wn-GH-164", parent: nil, kind: .composite, title: "Greeting workflow",
                 intent: "Store and display greetings", acceptanceCriteria: ["A saved greeting reaches the display"])
    }

    static func proposals(hasSeamPaths: Bool) -> [ChildProposal] {
        var storage = ChildProposal(
            title: "Save greeting", acceptanceCriteria: ["A greeting is stored"],
            touches: ["Storage", "Shared"], predictedPaths: ["Sources/Storage/Writer.swift"])
        storage.integration = false
        let presentation = ChildProposal(
            title: "Display greeting", acceptanceCriteria: ["A stored greeting is visible"],
            touches: ["Presentation", "Shared"], predictedPaths: ["Sources/Presentation"])
        var workflow = ChildProposal(
            title: "Combined workflow", acceptanceCriteria: ["A saved greeting reaches the display"],
            touches: ["Workflow", "Shared"],
            predictedPaths: hasSeamPaths ? ["Sources/Workflow", "Sources/Storage/Decoder.swift"] : nil)
        workflow.integration = true
        return [storage, presentation, workflow]
    }

    static func decomposerInstructions() -> String {
        CopilotDecomposer.prompt(for: BreakdownRequest(spec: Self.parent()))
            .components(separatedBy: "<<<SPEC")[0]
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
