// Expected API: runConfigurationRecorded(run:fingerprint:parts:) carries RunConfigurationParts;
// its harnessBuild is HarnessBuild(commit: String?, modified: Bool).
// Parts retain model, effort, agentRuntimeName and agentRuntimeVersion (not settings).
// WorkingState.runConfigurations[RunID] exposes the recorded fingerprint and parts.
// EventKind.summary is the text used by LedgerPane. The source-only constraint that event
// cases are added, never renamed or removed, is reviewed against the diff.
// Legacy string harnessBuild values must decode and retain their wire shape when re-encoded.
import Foundation
import Testing
import AgentOSCore

@Suite struct GH_153Tests {
    @Test(arguments: [
        ("92fe9f3abcdef0123456789abcdef0123456789abcd", false, "copilot", "1.0.114", "relay",
         "run-abc123 configuration 1a2b3c4d: harness 92fe9f3, copilot 1.0.114, relay"),
        ("92fe9f3abcdef0123456789abcdef0123456789abcd", true, "copilot", "1.0.114", "relay",
         "run-abc123 configuration 1a2b3c4d: harness 92fe9f3 (modified), copilot 1.0.114, relay"),
        (nil, false, "copilot", "1.0.114", "relay",
         "run-abc123 configuration 1a2b3c4d: harness unknown, copilot 1.0.114, relay"),
        ("1234567abcdef0123456789abcdef0123456789abc", false, "other-runtime", "2.5.0", "single-owner",
         "run-abc123 configuration 1a2b3c4d: harness 1234567, other-runtime 2.5.0, single-owner"),
    ])
    func ledgerDescribesTheRecordedRunConfiguration(
        commit: String?, modified: Bool, runtime: String, version: String, pipeline: String, expected: String
    ) {
        let parts = Self.parts(
            commit: commit, modified: modified, runtime: runtime, version: version, pipeline: pipeline
        )
        let event = EventKind.runConfigurationRecorded(run: "run-abc123", fingerprint: Self.fingerprint, parts: parts)

        #expect(event.summary == expected)
    }

    @Test func workingStateKeepsEachRunsOriginalConfigurationAfterFallbackAndLaterRuns() async throws {
        let ledger = try Ledger()
        let first = Self.parts()
        let second = Self.parts(
            commit: "1234567abcdef0123456789abcdef0123456789abc", modified: true,
            role: .testAuthor, model: "another-model", effort: "medium",
            policy: #"{"guesswork":"ask","review":{"maxRounds":3}}"#, version: "1.0.115"
        )
        let secondFingerprint = String(repeating: "b", count: 64)
        try await ledger.append([
            Self.event(.nodeCreated(spec: Self.spec("node-a"), ticket: "A-1")),
            Self.event(.runStarted(run: "first", role: .implementer)),
            Self.event(.agentConfigured(run: "first", settings: AgentRunSettings(model: first.model, effort: first.effort))),
            Self.event(.runConfigurationRecorded(run: "first", fingerprint: Self.fingerprint, parts: first)),
        ])
        try Self.expectConfiguration(
            await ledger.workingState(), run: "first", fingerprint: Self.fingerprint, parts: first
        )

        try await ledger.append([
            Self.event(.agentConfigured(
                run: "first", settings: AgentRunSettings(model: "fallback-model", effort: "low", fallback: "Unavailable model")
            )),
            Self.event(.runFinished(run: "first", outcome: "failed")),
            Self.event(.runStarted(run: "second", role: .testAuthor)),
            Self.event(.agentConfigured(run: "second", settings: AgentRunSettings(model: second.model, effort: second.effort))),
            Self.event(.runConfigurationRecorded(run: "second", fingerprint: secondFingerprint, parts: second)),
            Self.event(.runFinished(run: "second", outcome: "tests written")),
            Self.event(.nodeCreated(spec: Self.spec("node-b"), ticket: "B-1"), node: "node-b"),
            Self.event(.runStarted(run: "without-record", role: .implementer), node: "node-b"),
            Self.event(.agentConfigured(
                run: "without-record", settings: AgentRunSettings(model: first.model, effort: first.effort)
            ), node: "node-b"),
        ])
        let live = await ledger.workingState()
        try Self.expectConfiguration(live, run: "first", fingerprint: Self.fingerprint, parts: first)
        try Self.expectConfiguration(live, run: "second", fingerprint: secondFingerprint, parts: second)
        #expect(live.runConfigurations["without-record"] == nil)
        #expect(live.runConfigurations["never-started"] == nil)

        let persisted = Hashing.canonicalJSON(await ledger.allRecords())
        let store = InMemoryLedgerStore()
        store.append(try Hashing.decoder().decode([RecordedEvent].self, from: persisted))
        let reloaded = try Ledger(store: store)
        let replayed = await reloaded.workingState()
        try Self.expectConfiguration(replayed, run: "first", fingerprint: Self.fingerprint, parts: first)
        try Self.expectConfiguration(replayed, run: "second", fingerprint: secondFingerprint, parts: second)
        #expect(replayed.runConfigurations["without-record"] == nil)
        #expect(await reloaded.verifyChain().isIntact)
    }

    @Test func configurationsAreIndexedByRunRatherThanByNode() async throws {
        let ledger = try Ledger()
        let first = Self.parts()
        let other = Self.parts(role: .diagnoser, model: "diagnosis-model", effort: "max")
        let otherFingerprint = String(repeating: "c", count: 64)
        try await ledger.append([
            Self.event(.nodeCreated(spec: Self.spec("node-a"), ticket: "A-1")),
            Self.event(.nodeCreated(spec: Self.spec("node-b"), ticket: "B-1"), node: "node-b"),
            Self.event(.runStarted(run: "node-a-run", role: .implementer)),
            Self.event(.runConfigurationRecorded(run: "node-a-run", fingerprint: Self.fingerprint, parts: first)),
            Self.event(.runStarted(run: "node-b-run", role: .diagnoser), node: "node-b"),
            Self.event(.runConfigurationRecorded(
                run: "node-b-run", fingerprint: otherFingerprint, parts: other
            ), node: "node-b"),
        ])
        let state = await ledger.workingState()

        try Self.expectConfiguration(state, run: "node-a-run", fingerprint: Self.fingerprint, parts: first)
        try Self.expectConfiguration(state, run: "node-b-run", fingerprint: otherFingerprint, parts: other)
        #expect(state.runConfigurations["node-a"] == nil)
        #expect(state.runConfigurations["node-b"] == nil)
    }

    @Test func aNodeLessPreviewKeepsItsConfigurationAfterFinishing() async throws {
        let ledger = try Ledger()
        let parts = Self.parts(role: .decomposer, model: "preview-model", effort: "medium")
        try await ledger.append([
            Self.event(.previewStarted(ticket: "PREVIEW-1", node: "unadopted-node", run: "preview-run"), node: nil),
            Self.event(.runConfigurationRecorded(run: "preview-run", fingerprint: Self.fingerprint, parts: parts), node: nil),
        ])
        let active = await ledger.workingState()
        #expect(active.nodes["unadopted-node"] == nil)
        try Self.expectConfiguration(active, run: "preview-run", fingerprint: Self.fingerprint, parts: parts)

        try await ledger.append([
            Self.event(.previewFinished(ticket: "PREVIEW-1", run: "preview-run", outcome: "posted"), node: nil),
        ])
        let finished = await ledger.workingState()
        #expect(finished.runningPreviews["PREVIEW-1"] == nil)
        try Self.expectConfiguration(finished, run: "preview-run", fingerprint: Self.fingerprint, parts: parts)
    }

    @Test func runsWithoutAConfigurationEventHaveNoConfiguration() async throws {
        let ledger = try Ledger()
        #expect(await ledger.workingState().runConfigurations["not-started"] == nil)
        let settings = AgentRunSettings(model: "model", effort: "high")
        try await ledger.append([
            Self.event(.nodeCreated(spec: Self.spec("node-a"), ticket: "A-1")),
            Self.event(.runStarted(run: "finished", role: .testAuthor)),
            Self.event(.agentConfigured(run: "finished", settings: settings)),
            Self.event(.runFinished(run: "finished", outcome: "failed")),
            Self.event(.runStarted(run: "active", role: .implementer)),
            Self.event(.agentConfigured(run: "active", settings: settings)),
            Self.event(.previewStarted(ticket: "PREVIEW-1", node: "unadopted-node", run: "preview"), node: nil),
            Self.event(.agentConfigured(run: "preview", settings: settings), node: nil),
        ])
        let state = await ledger.workingState()

        for run in ["finished", "active", "preview", "not-started"] {
            #expect(state.runConfigurations[run] == nil)
        }
    }

    @Test func aLegacyLedgerStillVerifiesAndReplaysItsExistingWorkingState() async throws {
        let records = try Self.legacyRecords()
        let store = InMemoryLedgerStore()
        store.append(records)
        let ledger = try Ledger(store: store)
        let chain = await ledger.verifyChain()
        #expect(chain.isIntact, "\(chain.problem?.reason ?? "")")
        #expect(chain.checked == records.count)
        let state = await ledger.workingState()
        let parent = try #require(state.nodes["old-parent"])
        let leaf = try #require(state.nodes["old-leaf"])

        #expect(state.asOf == records.count - 1)
        #expect(state.creationOrder == ["old-parent", "old-leaf"])
        #expect(parent.spec == Self.spec("old-parent", kind: .composite))
        #expect(parent.ticket == "OLD-1")
        #expect(parent.version == 2)
        #expect(parent.phase == .specified)
        #expect(parent.children == ["old-leaf"])
        #expect(parent.gates == [.build])
        #expect(parent.activeRun == nil)
        #expect(leaf.spec == Self.spec("old-leaf", parent: "old-parent"))
        #expect(leaf.ticket == "OLD-2")
        #expect(leaf.version == 8)
        #expect(leaf.phase == .building)
        #expect(leaf.testsDigest == "legacy-tests")
        #expect(leaf.flags.isEmpty)
        #expect(state.hasGate(.build, at: leaf.id))
        #expect(leaf.activeRun?.run == "old-active")
        #expect(leaf.activeRun?.role == .implementer)
        #expect(leaf.activeRun?.since == Date(timeIntervalSince1970: 1_735_689_600))
        #expect(leaf.latestRun?.run == "old-active")
        #expect(leaf.latestRun?.role == .implementer)
        #expect(leaf.latestRun?.phase == .building)
        #expect(leaf.latestRun?.outcome == nil)
        #expect(leaf.agentRunsSinceHuman == 2)
        #expect(leaf.recordedAICredits == 0)
        #expect(leaf.runsWithoutRecordedCost == 2)
        let preview = try #require(state.runningPreviews["OLD-3"])
        #expect(preview.node == "old-preview-node")
        #expect(preview.run == "old-preview")
        #expect(preview.settings == AgentRunSettings(model: "preview-model", effort: "medium"))
        #expect(state.resolvedExternal.contains("EXT-1"))
        #expect(state.mainFetchWarning == "Legacy fetch warning")
        #expect(state.safeStop == "Legacy stop")
        for run in ["old-finished", "old-active", "old-preview"] {
            #expect(state.runConfigurations[run] == nil)
        }
    }

    @Test func aChangedLegacyRecordStillFailsHashChainVerification() async throws {
        var objects = try #require(
            JSONSerialization.jsonObject(with: Data(LegacyFixture.json.utf8)) as? [[String: Any]]
        )
        var event = try #require(objects[0]["event"] as? [String: Any])
        event["at"] = "2025-01-02T00:00:00Z"
        objects[0]["event"] = event
        let data = try JSONSerialization.data(withJSONObject: objects)
        let changedRecords = try Hashing.decoder().decode([RecordedEvent].self, from: data)
        let store = InMemoryLedgerStore()
        store.append(changedRecords)
        let ledger = try Ledger(store: store)
        let chain = await ledger.verifyChain()

        #expect(!chain.isIntact)
        #expect(chain.problem?.position == 0)
    }

    @Test(arguments: [
        (0, "run-legacy-modified", "23e9c31b3c8977ee4b02153183d8395eeb2986580ae2061f3895788480afb7bb",
         "92fe9f3" as String?, true,
         "run-legacy-modified configuration 23e9c31b: harness 92fe9f3 (modified), copilot 1.0.114, relay"),
        (1, "run-legacy-unknown", "d4ea5cf7be24c938b1b047a16d9681a2f82097fcfa126fe5309900864c69863e",
         nil, false,
         "run-legacy-unknown configuration d4ea5cf7: harness unknown, copilot 1.0.114, relay"),
    ])
    func legacyStringBuildConfigurationsStillVerifyReplayAndDescribeTheBuild(
        position: Int, run: RunID, fingerprint: String, commit: String?, modified: Bool, summary: String
    ) async throws {
        let records = try Hashing.decoder().decode(
            [RecordedEvent].self, from: Data(LegacyFixture.configurationJSON.utf8)
        )
        let store = InMemoryLedgerStore()
        store.append(records)
        let ledger = try Ledger(store: store)
        let reencoded = Hashing.canonicalJSON(await ledger.allRecords())
        let reloadedStore = InMemoryLedgerStore()
        reloadedStore.append(try Hashing.decoder().decode([RecordedEvent].self, from: reencoded))
        let reloaded = try Ledger(store: reloadedStore)

        for replayedLedger in [ledger, reloaded] {
            let chain = await replayedLedger.verifyChain()
            #expect(chain.isIntact, "\(chain.problem?.reason ?? "")")
            #expect(chain.checked == records.count)
            #expect(await replayedLedger.allRecords()[position].event.kind.summary == summary)
            let state = await replayedLedger.workingState()
            let configuration = try #require(state.runConfigurations[run])
            #expect(configuration.fingerprint == fingerprint)
            #expect(configuration.parts.harnessBuild.commit == commit)
            #expect(configuration.parts.harnessBuild.modified == modified)
            #expect(configuration.parts.role == .implementer)
            #expect(configuration.parts.model == "legacy-model")
            #expect(configuration.parts.effort == "high")
            #expect(configuration.parts.agentRuntimeName == "copilot")
            #expect(configuration.parts.agentRuntimeVersion == "1.0.114")
            #expect(configuration.parts.pipelineVariant == "relay")
            let policy = try #require(JSONSerialization.jsonObject(
                with: Data(configuration.parts.effectivePolicyJSON.utf8)
            ) as? [String: String])
            #expect(policy == ["guesswork": "ask"])
        }
    }

    private static let fingerprint = "1a2b3c4d" + String(repeating: "e", count: 56)

    private static func parts(
        commit: String? = "92fe9f3abcdef0123456789abcdef0123456789abcd",
        modified: Bool = false, role: AgentRole = .implementer,
        model: String = "original-model", effort: String = "high",
        policy: String = #"{"guesswork":"ask","review":{"maxRounds":2}}"#,
        runtime: String = "copilot", version: String = "1.0.114", pipeline: String = "relay"
    ) -> RunConfigurationParts {
        RunConfigurationParts(
            harnessBuild: HarnessBuild(commit: commit, modified: modified),
            effectivePolicyJSON: policy, role: role, model: model, effort: effort,
            agentRuntimeName: runtime, agentRuntimeVersion: version, pipelineVariant: pipeline
        )
    }

    private static func expectConfiguration(
        _ state: WorkingState, run: RunID, fingerprint: String, parts: RunConfigurationParts
    ) throws {
        let recorded = try #require(state.runConfigurations[run], "Configuration must be available for run \(run)")
        #expect(recorded.fingerprint == fingerprint)
        #expect(recorded.parts == parts)
    }

    private static func spec(_ id: NodeID, parent: NodeID? = nil, kind: NodeKind = .leaf) -> NodeSpec {
        NodeSpec(
            id: id, parent: parent, kind: kind, title: id, intent: "Legacy work",
            acceptanceCriteria: ["Legacy acceptance"], touches: ["Engine"]
        )
    }

    private static func event(_ kind: EventKind, node: NodeID? = "node-a") -> LedgerEvent {
        LedgerEvent(node: node, by: .reconciler, kind: kind, at: Date(timeIntervalSince1970: 1_735_689_600))
    }

    private static func legacyRecords() throws -> [RecordedEvent] {
        try Hashing.decoder().decode([RecordedEvent].self, from: Data(LegacyFixture.json.utf8))
    }
}
