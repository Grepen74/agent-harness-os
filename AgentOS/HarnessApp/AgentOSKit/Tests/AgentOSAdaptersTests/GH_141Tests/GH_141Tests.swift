// Expected API: ChildProposal.affectedTests: [String]? and NodeSpec.affectedTests: [String] (default []).
// Existing Planner.childSpecs, NodeSpec.specHash, ledger/replanning and CopilotDecomposer.prompt APIs
// carry the field without changing older specs' fingerprints or ledger hashes.
// Source-only AC5: README.md and docs/real-repo-mode.md describe the breakdown child's affectedTests.
import Foundation
import Testing
@testable import AgentOSAdapters
@testable import AgentOSCore

@Suite struct GH_141Tests {
    @Test(arguments: [false, true])
    func childProposalsDecodeNamesFilesMissingAndNullAffectedTests(bareArray: Bool) throws {
        let json = bareArray ? Self.proposalsJSON : #"{"children":\#(Self.proposalsJSON)}"#
        let breakdown = try #require(CopilotDecomposer.parse(json))
        try #require(breakdown.children.count == 4)
        #expect(breakdown.children[0].affectedTests == [Self.testName, "", Self.testFile])
        #expect(breakdown.children[1].affectedTests == nil)
        #expect(breakdown.children[2].affectedTests == nil)
        #expect(breakdown.children[3].affectedTests == [])

        let restored = try JSONDecoder().decode(
            [ChildProposal].self, from: JSONEncoder().encode(breakdown.children))
        #expect(restored.map(\.affectedTests) == breakdown.children.map(\.affectedTests))
    }

    @Test
    func plannerCopiesOnlyEachChildsNonemptyAffectedTests() throws {
        var proposals = try Self.proposals()
        proposals[1].affectedTests = ["", "DisplayTests.showsGreeting", ""]
        proposals[2].affectedTests = [""]
        let specs = Planner.childSpecs(parent: try Self.rootSpec(), proposals: proposals)
        try #require(specs.count == 4)
        #expect(specs[0].affectedTests == [Self.testName, Self.testFile])
        #expect(specs[1].affectedTests == ["DisplayTests.showsGreeting"])
        #expect(specs[2].affectedTests.isEmpty)
        #expect(specs[3].affectedTests.isEmpty)

        let older = try Self.proposals()[1]
        let withoutField = try #require(
            Planner.childSpecs(parent: Self.rootSpec(), proposals: [older]).first)
        #expect(withoutField.affectedTests.isEmpty)
    }

    @Test
    func nodeAndPreviewSpecsRetainAffectedTestsAfterLedgerReload() async throws {
        let specs = Planner.childSpecs(parent: try Self.rootSpec(), proposals: try Self.proposals())
        let ledger = try Ledger()
        let root = try Self.rootSpec()
        try await ledger.append([
            LedgerEvent(node: root.id, by: .human("Reviewer"), kind: .nodeCreated(spec: root, ticket: "GH-141"))
        ] + specs.enumerated().map { index, spec in
            LedgerEvent(node: spec.id, by: .reconciler,
                        kind: .nodeCreated(spec: spec, ticket: "GH-141-child-\(index + 1)"))
        } + [
            LedgerEvent(node: nil, by: .reconciler,
                        kind: .previewRecorded(ticket: "GH-141-preview", number: 1,
                                               specHash: root.specHash, proposal: specs))
        ])

        let reloaded = try await Self.reload(ledger)
        #expect(await reloaded.verifyChain().isIntact)
        let state = await reloaded.workingState()
        let preview = try #require(state.previews["GH-141-preview"])
        try #require(preview.proposal.count == specs.count)
        for (index, spec) in specs.enumerated() {
            let expected = index == 0 ? [Self.testName, Self.testFile] : []
            let node = try #require(state.nodes[spec.id])
            #expect(node.spec.affectedTests == expected)
            #expect(preview.proposal[index].affectedTests == expected)
        }
    }

    @Test
    func oldNodeAndPreviewRecordsReplayWithoutAffectedTests() async throws {
        let ledger = try Self.legacyLedger()
        #expect(await ledger.verifyChain().isIntact)
        let state = await ledger.workingState()
        let child = try #require(state.nodes[Self.childID])
        #expect(child.spec.title == "Save greeting")
        #expect(child.testsDigest == "existing-locked-tests")
        #expect(child.gates.contains(.build))
        #expect(child.phase == .ready)
        #expect(child.spec.affectedTests.isEmpty)
        let preview = try #require(state.previews["GH-141-preview"])
        try #require(preview.proposal.count == 2)
        #expect(preview.proposal[0].title == child.spec.title)
        #expect(preview.proposal.allSatisfy { $0.affectedTests.isEmpty })

        let reloaded = try await Self.reload(ledger)
        #expect(await reloaded.verifyChain().isIntact,
                "Re-encoding a legacy spec must not add empty affectedTests to its hashed event.")
    }

    @Test(arguments: ["omitted", "null", "empty"])
    func emptyAffectedTestsKeepTheLegacySpecHash(shape: String) throws {
        var json = try Self.object(Self.legacyChildJSON)
        if shape == "null" { json["affectedTests"] = NSNull() }
        if shape == "empty" { json["affectedTests"] = [String]() }
        let decoded = try JSONDecoder().decode(
            NodeSpec.self, from: JSONSerialization.data(withJSONObject: json))
        var explicitEmpty = try Self.legacyChildSpec()
        explicitEmpty.affectedTests = []
        #expect(decoded.affectedTests.isEmpty)
        #expect(decoded.specHash == Self.legacyChildHash)
        #expect(explicitEmpty.specHash == decoded.specHash)
    }

    @Test
    func addingOrChangingAffectedTestsChangesTheSpecHash() throws {
        let original = try Self.legacyChildSpec()
        var namedTest = original
        namedTest.affectedTests = [Self.testName]
        var testFile = original
        testFile.affectedTests = [Self.testFile]
        var both = original
        both.affectedTests = [Self.testName, Self.testFile]
        #expect(namedTest.specHash != original.specHash)
        #expect(testFile.specHash != original.specHash)
        #expect(namedTest.specHash != testFile.specHash)
        #expect(both.specHash != namedTest.specHash)
    }

    @Test(arguments: [false, true])
    func replanningKeepsOnlyChildrenWhoseAffectedTestsAreUnchanged(addAffectedTests: Bool) async throws {
        let ledger = try Self.legacyLedger()
        let before = await ledger.workingState()
        let root = try #require(before.nodes[Self.rootID])
        let original = try #require(before.nodes[Self.childID])
        var proposal = ChildProposal(title: original.spec.title,
                                     acceptanceCriteria: original.spec.acceptanceCriteria,
                                     touches: original.spec.touches)
        proposal.affectedTests = addAffectedTests ? [Self.testName] : []
        let display = try #require(before.nodes["\(Self.rootID).2"])
        let unchangedSibling = ChildProposal(title: display.spec.title,
                                            acceptanceCriteria: display.spec.acceptanceCriteria,
                                            touches: display.spec.touches)
        let tracker = Tracker()
        let services = BreakdownOnlyServices()
        let reconciler = Reconciler(
            ledger: ledger, tracker: tracker, external: services, workspace: services,
            artifacts: services, checks: services,
            team: AgentTeam(name: "GH-141", decomposer: Proposer(children: [proposal, unchangedSibling]),
                            testAuthor: services, implementer: services))
        let ticket = Ticket(key: root.ticket, title: root.spec.title, description: root.spec.intent,
                            acceptanceCriteria: root.spec.acceptanceCriteria, createdBy: .human("Reviewer"))
        _ = try await reconciler.replan(root, ticket: ticket, by: "Reviewer")
        try await ledger.append([
            LedgerEvent(node: root.id, by: .human("Reviewer"), kind: .gateOpened(.breakdown))
        ])
        let replanned = await ledger.workingState()
        _ = try await reconciler.breakDown(try #require(replanned.nodes[root.id]), in: replanned)

        let reloaded = try await Self.reload(ledger)
        let state = await reloaded.workingState()
        let updatedRoot = try #require(state.nodes[root.id])
        let children = updatedRoot.children.compactMap { state.nodes[$0] }
        let child = try #require(children.first { $0.spec.title == original.spec.title })
        #expect(children.count == 2)
        #expect(state.nodes[display.id]?.ticket == display.ticket)
        if addAffectedTests {
            #expect(child.ticket != original.ticket,
                    "A changed affected-test contract must not inherit the older child's tests or approval.")
            #expect(child.testsDigest == nil)
            #expect(!child.gates.contains(.build))
            #expect(child.spec.affectedTests == [Self.testName])
            #expect(await tracker.closedTickets.contains(original.ticket))
        } else {
            #expect(child.id == original.id)
            #expect(child.ticket == original.ticket)
            #expect(child.testsDigest == "existing-locked-tests")
            #expect(child.gates.contains(.build))
            #expect(child.spec.affectedTests.isEmpty)
            #expect(await tracker.createdTickets.isEmpty)
            #expect(await tracker.closedTickets.isEmpty)
        }
    }

    @Test
    func decomposerPromptIncludesAffectedTestsInEachChildShape() throws {
        let prompt = CopilotDecomposer.prompt(for: BreakdownRequest(spec: try Self.rootSpec()))
        #expect(Self.matches(prompt, #"(?s)"children"\s*:\s*\[\s*\{[^}]*"affectedTests"\s*:\s*\["#),
                "affectedTests belongs in the JSON shape of a child, not only in surrounding prose.")
    }

    @Test
    func decomposerPromptKeepsAffectedTestOwnershipAndNewExpectationsTogether() throws {
        let prompt = CopilotDecomposer.prompt(for: BreakdownRequest(spec: try Self.rootSpec()))
        let sentences = prompt.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: #"(?<=[.!?])\s+"#, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n")
        let affectedSentences = sentences.filter { $0.contains("affectedTests") }
        let affectedInstructions = affectedSentences.joined(separator: " ")
        #expect(Self.matches(affectedInstructions, #"(list|name|identify|record)"#))
        #expect(Self.matches(affectedInstructions, #"(existing|current|already).*tests|tests.*(existing|current|already)"#))
        #expect(Self.matches(affectedInstructions, #"(chang|break|supersed)"#))
        #expect(affectedSentences.contains {
            Self.matches($0, #"child"#) && Self.matches($0, #"tests"#)
                && Self.matches($0, #"\bcriteri(on|a)\b"#) && Self.matches($0, #"(expect|assert)"#)
        }, "An affectedTests instruction must give the changing child a criterion stating those tests' new expectations.")
    }
}

private extension GH_141Tests {
    static let rootID = "wn-GH-141"
    static let childID = "wn-GH-141.1"
    static let testName = "FlowTests.someTest"
    static let testFile = "AgentOS/HarnessApp/AgentOSKit/Tests/AgentOSSimulationTests/FlowTests.swift"
    static let legacyChildHash = "db6b0230c39dc1b69f5bedd8fafe0f42191a4b7876468d3bf7b1be9ebafa9431"

    static var proposalsJSON: String {
        """
        [
          {"title":"Save greeting","acceptanceCriteria":["A greeting is stored"],"touches":["Storage"],
           "affectedTests":["\(testName)","","\(testFile)"]},
          {"title":"Display greeting","acceptanceCriteria":["A greeting is visible"],"touches":["Display"]},
          {"title":"Speak greeting","acceptanceCriteria":["A greeting is spoken"],"affectedTests":null},
          {"title":"Print greeting","acceptanceCriteria":["A greeting is printed"],"affectedTests":[]}
        ]
        """
    }

    static var legacyRootJSON: String {
        """
        {"id":"wn-GH-141","kind":"composite","title":"Greeting features","intent":"Greet the user",
         "acceptanceCriteria":["A greeting is stored","A greeting is visible"],
         "touches":[],"dependsOn":[],"profile":"simple-app"}
        """
    }

    static var legacyChildJSON: String {
        """
        {"id":"wn-GH-141.1","parent":"wn-GH-141","kind":"leaf","title":"Save greeting",
         "intent":"Part of Greeting features","acceptanceCriteria":["A greeting is stored"],
         "touches":["Storage"],"dependsOn":[],"profile":"simple-app"}
        """
    }

    static func proposals() throws -> [ChildProposal] {
        try JSONDecoder().decode([ChildProposal].self, from: Data(proposalsJSON.utf8))
    }

    static func rootSpec() throws -> NodeSpec {
        try JSONDecoder().decode(NodeSpec.self, from: Data(legacyRootJSON.utf8))
    }

    static func legacyChildSpec() throws -> NodeSpec {
        try JSONDecoder().decode(NodeSpec.self, from: Data(legacyChildJSON.utf8))
    }

    static func object(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func reload(_ ledger: Ledger) async throws -> Ledger {
        let records = try Hashing.decoder().decode(
            [RecordedEvent].self, from: Hashing.canonicalJSON(await ledger.allRecords()))
        let store = InMemoryLedgerStore()
        store.append(records)
        return try Ledger(store: store)
    }

    static func legacyLedger() throws -> Ledger {
        let store = InMemoryLedgerStore()
        try store.append(legacyRecords())
        return try Ledger(store: store)
    }

    static func legacyRecords() throws -> [RecordedEvent] {
        // Build hashes from pre-field JSON, not from today's NodeSpec encoder.
        let root = try object(legacyRootJSON)
        let first = try object(legacyChildJSON)
        var second = first
        second["id"] = "\(rootID).2"
        second["title"] = "Display greeting"
        second["acceptanceCriteria"] = ["A greeting is visible"]
        second["touches"] = ["Display"]
        let kinds: [(String?, [String: Any])] = [
            (rootID, ["nodeCreated": ["spec": root, "ticket": "GH-141"]]),
            (childID, ["nodeCreated": ["spec": first, "ticket": "GH-141-old-save"]]),
            ("\(rootID).2", ["nodeCreated": ["spec": second, "ticket": "GH-141-old-display"]]),
            (rootID, ["phaseChanged": ["to": "split"]]),
            (childID, ["testsFixed": ["digest": "existing-locked-tests"]]),
            (childID, ["gateOpened": ["_0": "build"]]),
            (childID, ["phaseChanged": ["to": "ready"]]),
            (nil, ["previewRecorded": ["ticket": "GH-141-preview", "number": 1,
                                      "specHash": "legacy-root-fingerprint", "proposal": [first, second]]])
        ]
        var previousHash = RecordedEvent.genesisHash
        return try kinds.enumerated().map { position, entry in
            var event: [String: Any] = [
                "id": UUID().uuidString, "by": ["human": ["_0": "Reviewer"]],
                "at": "2025-01-01T00:00:00Z", "kind": entry.1
            ]
            if let node = entry.0 { event["node"] = node }
            var payload: [String: Any] = ["position": position, "previousHash": previousHash, "event": event]
            let bytes = try JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            previousHash = Hashing.sha256(bytes)
            payload["hash"] = previousHash
            return try Hashing.decoder().decode(
                RecordedEvent.self, from: JSONSerialization.data(withJSONObject: payload))
        }
    }
}
