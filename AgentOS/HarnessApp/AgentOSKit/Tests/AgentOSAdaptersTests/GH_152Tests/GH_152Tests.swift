// Expected API: EventKind.runConfigurationRecorded(run: RunID, fingerprint: String,
// parts: RunConfigurationParts). Parts are Codable, Sendable and Equatable, with harnessBuild,
// effectivePolicyJSON, role, model, effort, agentRuntimeName, agentRuntimeVersion and pipelineVariant.
// Reconciler.init accepts optional metadata through harnessBuild, agentRuntimeName,
// agentRuntimeVersion and effectivePolicyJSON, retaining the existing initializer defaults.
// All five GH-152 criteria describe observable behaviour; none are source-only.
// Parent build discovery, secret filtering, UI/state projections and documentation belong to siblings.
import Foundation
import Testing
import AgentOSCore
import AgentOSTestSupport

@Suite struct GH_152Tests {
    @Test(arguments: [AgentRole.testAuthor, .implementer, .decomposer, .diagnoser], [false, true])
    func aNodeRunRecordsExactlyOneConfigurationInItsStartWriteBeforeTheAgentActs(
        role: AgentRole, fails: Bool
    ) async throws {
        let fixture = try Fixture(role: role, fails: fails)
        defer { fixture.removeFiles() }
        try await fixture.seedAndRun()

        let snapshot = try #require(await fixture.agents.snapshots.first)
        let start = try Self.start(in: snapshot, role: role)
        let configuration = try Self.configuration(in: snapshot, run: start.run)
        #expect(configuration.node == fixture.spec.id)
        try Self.expectSameWrite(fixture.store, start: start.record, configuration: configuration.record)
        try Self.expectParts(configuration.parts, role: role, options: fixture.options)
        try Self.expectInitialSettings(in: snapshot, run: start.run, parts: configuration.parts)
        #expect(!Self.hasFinished(snapshot, run: start.run))

        let completed = await fixture.ledger.allRecords()
        let final = try Self.configuration(in: completed, run: start.run)
        #expect(final.record.event.id == configuration.record.event.id)
        #expect(Self.hasFinished(completed, run: start.run))
        #expect(await fixture.agents.calls == 1)

        let restored = try Ledger(store: fixture.store)
        #expect(await restored.verifyChain().isIntact)
        let replayed = try Self.configuration(in: await restored.allRecords(), run: start.run)
        #expect(replayed.fingerprint == configuration.fingerprint)
        #expect(replayed.parts == configuration.parts)
    }

    @Test(arguments: [false, true])
    func aPreviewRecordsExactlyOneNodelessConfigurationInItsPreviewStartWrite(fails: Bool) async throws {
        let fixture = try Fixture(role: .decomposer, preview: true, fails: fails)
        defer { fixture.removeFiles() }
        try await fixture.seedAndRun()

        let snapshot = try #require(await fixture.agents.snapshots.first)
        let start = try Self.start(in: snapshot, role: .decomposer, preview: true)
        let configuration = try Self.configuration(in: snapshot, run: start.run)
        #expect(start.record.event.node == nil)
        #expect(configuration.node == nil)
        try Self.expectSameWrite(fixture.store, start: start.record, configuration: configuration.record)
        try Self.expectParts(configuration.parts, role: .decomposer, options: fixture.options)
        try Self.expectInitialSettings(in: snapshot, run: start.run, parts: configuration.parts)
        #expect(!Self.hasFinished(snapshot, run: start.run))

        let records = await fixture.ledger.allRecords()
        #expect(Self.hasFinished(records, run: start.run))
        #expect(try Self.configuration(in: records, run: start.run).record.event.id == configuration.record.event.id)
        #expect(await fixture.ledger.workingState().nodes.isEmpty)
        #expect(await fixture.agents.calls == 1)
    }

    @Test
    func verifierRunsHaveNoConfigurationRecord() async throws {
        let fixture = try Fixture(role: .verifier)
        defer { fixture.removeFiles() }
        try await fixture.seedAndRun()

        let records = await fixture.ledger.allRecords()
        let runs = records.compactMap { record -> RunID? in
            guard case .runStarted(let run, .verifier) = record.event.kind else { return nil }
            return run
        }
        try #require(!runs.isEmpty, "The fixture must actually run verification.")
        #expect(runs.allSatisfy { Self.hasFinished(records, run: $0) })
        #expect(Self.configurations(in: records).isEmpty)
        #expect(await fixture.agents.calls == 0)
    }

    @Test(arguments: [false, true])
    func absentAgentSettingsStillRecordExactlyOneConfigurationInTheStartWrite(
        settingsProvider: Bool
    ) async throws {
        var options = Options()
        options.settingsAvailable = false
        let fixture = try Fixture(role: .implementer, settingsProvider: settingsProvider, options: options)
        defer { fixture.removeFiles() }
        try await fixture.seedAndRun()
        let snapshot = try #require(await fixture.agents.snapshots.first)
        let start = try Self.start(in: snapshot, role: .implementer)
        let configuration = try Self.configuration(in: snapshot, run: start.run)
        try Self.expectSameWrite(fixture.store, start: start.record, configuration: configuration.record)
        #expect(configuration.parts.role == .implementer)
        #expect(Self.settings(in: snapshot, run: start.run).isEmpty)
        try Self.expectFingerprint(configuration)
    }

    @Test(arguments: [AgentRole.testAuthor, .implementer, .decomposer, .diagnoser], [false, true])
    func aModelFallbackRecordsNewSettingsButKeepsTheNodeRunsStartingFingerprintAndParts(
        role: AgentRole, fails: Bool
    ) async throws {
        let fixture = try Fixture(role: role, fails: fails, fallback: true)
        defer { fixture.removeFiles() }
        try await fixture.seedAndRun()
        try await Self.expectFallbackKeepsConfiguration(fixture)
    }

    @Test(arguments: [false, true])
    func aPreviewFallbackKeepsItsStartingFingerprintAndParts(fails: Bool) async throws {
        let fixture = try Fixture(role: .decomposer, preview: true, fails: fails, fallback: true)
        defer { fixture.removeFiles() }
        try await fixture.seedAndRun()
        try await Self.expectFallbackKeepsConfiguration(fixture)
    }

    @Test
    func missingMetadataRecordsUnknownsAndTheReconcilerAgentWorkPolicy() async throws {
        var policy = Policy(maxAttempts: 7, maxReworks: 8, maxAgentRuns: 23, maxParallelAgents: 3,
                            protectedPaths: ["private/*", "AGENTS.md"], guesswork: .autonomous,
                            landingBatchSize: 5)
        policy.review.level = .agentAndHuman
        policy.review.areas = ["Sources": .agent, "Engine": .none]
        policy.review.maxRounds = 4
        var options = Options()
        options.policy = policy
        options.suppliedMetadata = false
        let fixture = try Fixture(role: .implementer, options: options)
        defer { fixture.removeFiles() }
        try await fixture.seedAndRun()

        let configuration = try Self.onlyConfiguration(in: await fixture.ledger.allRecords())
        #expect(configuration.parts.harnessBuild.commit == nil)
        #expect(configuration.parts.harnessBuild.modified == false)
        #expect(configuration.parts.agentRuntimeName == "unknown")
        #expect(configuration.parts.agentRuntimeVersion == "unknown")
        #expect(configuration.parts.pipelineVariant == "relay")
        let json = try Self.object(configuration.parts.effectivePolicyJSON)
        let review = try #require(json["review"] as? [String: Any])
        #expect(review["level"] as? String == policy.review.level.rawValue)
        #expect(review["maxRounds"] as? Int == policy.review.maxRounds)
        #expect(review["areas"] as? [String: String] == ["Sources": "agent", "Engine": "none"])
        #expect(json["guesswork"] as? String == policy.guesswork.rawValue)
        #expect(json["maxAttempts"] as? Int == policy.maxAttempts)
        #expect(json["maxReworks"] as? Int == policy.maxReworks)
        #expect(json["maxAgentRuns"] as? Int == policy.maxAgentRuns)
        #expect(json["maxParallelAgents"] as? Int == policy.maxParallelAgents)
        #expect(json["landingBatchSize"] as? Int == policy.landingBatchSize)
        #expect(json["protectedPaths"] as? [String] == policy.protectedPaths)
        for keys in [
            ["guesswork", "landingBatchSize", "maxAgentRuns", "maxAttempts", "maxParallelAgents",
             "maxReworks", "protectedPaths", "review"],
            ["areas", "level", "maxRounds"],
            ["Engine", "Sources"],
        ] {
            let positions = try keys.sorted().map { key in
                try #require(configuration.parts.effectivePolicyJSON.range(of: "\"\(key)\"")).lowerBound
            }
            #expect(positions == positions.sorted(), "Default policy keys must be sorted, including nested keys.")
        }
        try Self.expectFingerprint(configuration)
    }

    @Test
    func theRecordedFingerprintIsLowercaseHexSHA256OfTheCanonicalParts() async throws {
        let fixture = try Fixture(role: .implementer)
        defer { fixture.removeFiles() }
        try await fixture.seedAndRun()
        let configuration = try Self.onlyConfiguration(in: await fixture.ledger.allRecords())
        try Self.expectFingerprint(configuration)
    }

    @Test
    func identicalConfigurationOnDifferentTicketsAndRunIDsHasTheSameFingerprint() async throws {
        let first = try Fixture(role: .implementer, id: "first-ticket")
        defer { first.removeFiles() }
        let second = try Fixture(role: .implementer, id: "other-ticket")
        defer { second.removeFiles() }
        try await first.seedAndRun()
        try await second.seedAndRun()
        let a = try Self.onlyConfiguration(in: await first.ledger.allRecords())
        let b = try Self.onlyConfiguration(in: await second.ledger.allRecords())

        #expect(a.run != b.run)
        #expect(a.node != b.node)
        #expect(a.parts == b.parts)
        #expect(a.fingerprint == b.fingerprint)
        try Self.expectFingerprint(a)
        try Self.expectFingerprint(b)
    }

    @Test(arguments: ["harnessBuild", "effectivePolicyJSON", "role", "model", "effort",
                      "agentRuntimeName", "agentRuntimeVersion"])
    func changingAnyConfigurablePartChangesTheFingerprint(part: String) async throws {
        let baseline = try Fixture(role: .implementer)
        defer { baseline.removeFiles() }
        var changed = Options()
        var role = AgentRole.implementer
        switch part {
        case "harnessBuild": changed.harnessBuild = HarnessBuild(commit: "other-build", modified: true)
        case "effectivePolicyJSON": changed.effectivePolicyJSON = #"{"limit":7,"review":{"level":"agent+human"}}"#
        case "role": role = .testAuthor
        case "model": changed.model = "other-model"
        case "effort": changed.effort = "medium"
        case "agentRuntimeName": changed.agentRuntimeName = "other-runtime"
        case "agentRuntimeVersion": changed.agentRuntimeVersion = "2.0"
        default: Issue.record("Unknown configuration part: \(part)")
        }
        let variant = try Fixture(role: role, options: changed)
        defer { variant.removeFiles() }
        try await baseline.seedAndRun()
        try await variant.seedAndRun()
        let a = try Self.onlyConfiguration(in: await baseline.ledger.allRecords())
        let b = try Self.onlyConfiguration(in: await variant.ledger.allRecords())
        #expect(a.fingerprint != b.fingerprint, "Changing \(part) must change the fingerprint.")
        try Self.expectFingerprint(a)
        try Self.expectFingerprint(b)
    }

    @Test
    func reorderingPolicyKeysIncludingNestedKeysDoesNotChangeTheFingerprint() async throws {
        var aOptions = Options()
        aOptions.effectivePolicyJSON = #"{"z":7,"review":{"level":"agent","areas":{"UI":"none","Core":"agent"}},"a":true}"#
        var bOptions = aOptions
        bOptions.effectivePolicyJSON = #"{"a":true,"review":{"areas":{"Core":"agent","UI":"none"},"level":"agent"},"z":7}"#
        let first = try Fixture(role: .implementer, options: aOptions)
        defer { first.removeFiles() }
        let second = try Fixture(role: .implementer, options: bOptions)
        defer { second.removeFiles() }
        try await first.seedAndRun()
        try await second.seedAndRun()
        let a = try Self.onlyConfiguration(in: await first.ledger.allRecords())
        let b = try Self.onlyConfiguration(in: await second.ledger.allRecords())
        #expect(NSDictionary(dictionary: try Self.object(a.parts.effectivePolicyJSON))
            .isEqual(to: try Self.object(b.parts.effectivePolicyJSON)))
        #expect(a.fingerprint == b.fingerprint)
    }

    @Test(arguments: ["review.level", "review.areas", "review.maxRounds", "guesswork", "maxAttempts",
                      "maxReworks", "maxAgentRuns", "maxParallelAgents", "landingBatchSize", "protectedPaths"])
    func eachAgentWorkPolicySettingAffectsTheDefaultPolicyFingerprint(setting: String) async throws {
        var options = Options()
        options.suppliedMetadata = false
        let baseline = try Fixture(role: .implementer, options: options)
        defer { baseline.removeFiles() }
        switch setting {
        case "review.level": options.policy.review.level = .none
        case "review.areas": options.policy.review.areas = ["Engine": .agentAndHuman]
        case "review.maxRounds": options.policy.review.maxRounds += 1
        case "guesswork": options.policy.guesswork = .autonomous
        case "maxAttempts": options.policy.maxAttempts += 1
        case "maxReworks": options.policy.maxReworks += 1
        case "maxAgentRuns": options.policy.maxAgentRuns += 1
        case "maxParallelAgents": options.policy.maxParallelAgents += 1
        case "landingBatchSize": options.policy.landingBatchSize += 1
        case "protectedPaths": options.policy.protectedPaths = ["AGENTS.md"]
        default: Issue.record("Unknown policy setting: \(setting)")
        }
        let variant = try Fixture(role: .implementer, options: options)
        defer { variant.removeFiles() }
        try await baseline.seedAndRun()
        try await variant.seedAndRun()
        let a = try Self.onlyConfiguration(in: await baseline.ledger.allRecords())
        let b = try Self.onlyConfiguration(in: await variant.ledger.allRecords())
        #expect(a.fingerprint != b.fingerprint, "The default policy must include \(setting).")
        try Self.expectFingerprint(a)
        try Self.expectFingerprint(b)
    }

    @Test(arguments: [false, true])
    func theFixtureObservesExistingClaimsSettingsAndSuccessfulAgentCompletion(fallback: Bool) async throws {
        let fixture = try Fixture(role: .implementer, fallback: fallback)
        defer { fixture.removeFiles() }
        try await fixture.seedAndRun()
        let snapshot = try #require(await fixture.agents.snapshots.first)
        let start = try Self.start(in: snapshot, role: .implementer)
        let settings = try #require(Self.settings(in: snapshot, run: start.run).first)
        #expect(settings == fixture.options.settings)
        #expect(!Self.hasFinished(snapshot, run: start.run))
        let records = await fixture.ledger.allRecords()
        #expect(Self.hasFinished(records, run: start.run))
        #expect(Self.settings(in: records, run: start.run)
            == (fallback ? [fixture.options.settings, Fixture.fallbackSettings] : [fixture.options.settings]))
        #expect(records.contains {
            if case .changeSubmitted(let run, _) = $0.event.kind { return run == start.run }
            return false
        })
        #expect(fixture.store.batches.flatMap { $0 }.map(\.event.id) == records.map(\.event.id))
        #expect(await fixture.ledger.verifyChain().isIntact)
        #expect(await fixture.agents.calls == 1)
    }
}

private extension GH_152Tests {
    struct Configuration {
        let record: RecordedEvent
        let run: RunID
        let fingerprint: String
        let parts: RunConfigurationParts
        var node: NodeID? { record.event.node }
    }

    static func configurations(in records: [RecordedEvent]) -> [Configuration] {
        records.compactMap {
            guard case .runConfigurationRecorded(let run, let fingerprint, let parts) = $0.event.kind else { return nil }
            return Configuration(record: $0, run: run, fingerprint: fingerprint, parts: parts)
        }
    }

    static func configuration(in records: [RecordedEvent], run: RunID) throws -> Configuration {
        let matching = Self.configurations(in: records).filter { $0.run == run }
        #expect(matching.count == 1, "Every agent start must have exactly one configuration record for \(run).")
        return try #require(matching.first, "The configuration must already be durable when the agent is called.")
    }

    static func onlyConfiguration(in records: [RecordedEvent]) throws -> Configuration {
        let configurations = Self.configurations(in: records)
        #expect(configurations.count == 1)
        return try #require(configurations.first, "The run must record its configuration.")
    }

    static func start(in records: [RecordedEvent], role: AgentRole, preview: Bool = false)
        throws -> (record: RecordedEvent, run: RunID) {
        let starts = records.compactMap { record -> (RecordedEvent, RunID)? in
            if preview, case .previewStarted(_, _, let run) = record.event.kind { return (record, run) }
            if !preview, case .runStarted(let run, let startedRole) = record.event.kind, startedRole == role {
                return (record, run)
            }
            return nil
        }
        #expect(starts.count == 1, "The fixture must drive the requested run, not just append test events.")
        return try #require(starts.first)
    }

    static func hasFinished(_ records: [RecordedEvent], run: RunID) -> Bool {
        records.contains {
            switch $0.event.kind {
            case .runFinished(let finished, _), .previewFinished(_, let finished, _): return finished == run
            default: return false
            }
        }
    }

    static func settings(in records: [RecordedEvent], run: RunID) -> [AgentRunSettings] {
        records.compactMap {
            guard case .agentConfigured(let configured, let settings) = $0.event.kind, configured == run else { return nil }
            return settings
        }
    }

    static func expectSameWrite(_ store: BatchStore, start: RecordedEvent, configuration: RecordedEvent) throws {
        let write = try #require(store.batches.first { $0.contains { $0.event.id == start.event.id } })
        #expect(write.contains { $0.event.id == configuration.event.id },
                "The run claim and configuration must persist atomically, not in adjacent appends.")
        let recorded = Self.configurations(in: write)
        #expect(recorded.filter { $0.run == Self.configurationRun(configuration) }.count == 1)
    }

    static func configurationRun(_ record: RecordedEvent) -> RunID? {
        guard case .runConfigurationRecorded(let run, _, _) = record.event.kind else { return nil }
        return run
    }

    static func expectParts(_ parts: RunConfigurationParts, role: AgentRole, options: Options) throws {
        #expect(parts.harnessBuild.commit == options.harnessBuild.commit)
        #expect(parts.harnessBuild.modified == options.harnessBuild.modified)
        #expect(parts.agentRuntimeName == options.agentRuntimeName)
        #expect(parts.agentRuntimeVersion == options.agentRuntimeVersion)
        #expect(parts.role == role)
        #expect(parts.model == options.settings.model)
        #expect(parts.effort == options.settings.effort)
        #expect(parts.pipelineVariant == "relay")
        let expected = try #require(options.effectivePolicyJSON)
        #expect(NSDictionary(dictionary: try Self.object(parts.effectivePolicyJSON))
            .isEqual(to: try Self.object(expected)), "Supplied effective policy takes precedence over the Policy projection.")
    }

    static func expectInitialSettings(in records: [RecordedEvent], run: RunID, parts: RunConfigurationParts) throws {
        let configured = Self.settings(in: records, run: run)
        #expect(configured.count == 1)
        let initial = try #require(configured.first)
        #expect(initial.fallback == nil)
        #expect(parts.model == initial.model)
        #expect(parts.effort == initial.effort)
    }

    static func expectFallbackKeepsConfiguration(_ fixture: Fixture) async throws {
        let snapshot = try #require(await fixture.agents.snapshots.first)
        let start = try Self.start(in: snapshot, role: fixture.role, preview: fixture.preview)
        let initial = try Self.configuration(in: snapshot, run: start.run)
        try Self.expectInitialSettings(in: snapshot, run: start.run, parts: initial.parts)
        let finished = await fixture.ledger.allRecords()
        let configured = Self.settings(in: finished, run: start.run)
        #expect(configured.count == 2)
        #expect(configured.first == fixture.options.settings)
        #expect(configured.last == Fixture.fallbackSettings)
        let final = try Self.configuration(in: finished, run: start.run)
        #expect(final.record.event.id == initial.record.event.id)
        #expect(final.fingerprint == initial.fingerprint)
        #expect(final.parts == initial.parts)
        #expect(final.parts.model != Fixture.fallbackSettings.model)
        #expect(final.parts.effort != Fixture.fallbackSettings.effort)
        #expect(Self.hasFinished(finished, run: start.run))
        try Self.expectFingerprint(final)
    }

    static func object(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    static func expectFingerprint(_ configuration: Configuration) throws {
        let fingerprint = configuration.fingerprint
        #expect(fingerprint.utf8.count == 64)
        #expect(fingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        let fingerprints = try [JSONEncoder.OutputFormatting.sortedKeys,
                                [.sortedKeys, .withoutEscapingSlashes]].map { formatting in
            let encoder = JSONEncoder()
            encoder.outputFormatting = formatting
            return Hashing.sha256(try encoder.encode(configuration.parts))
        }
        #expect(fingerprints.contains(fingerprint),
                "The fingerprint must hash the recorded parts, not the run ID, ticket, or an omitted subset.")
    }
}
