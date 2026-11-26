// Expected API: RepositorySession supplies its effective repo policy to Reconciler.agentRunStarted.
// That existing claim builder emits a Codable EventKind.runConfigurationRecorded whose payload has
// run: String, fingerprint: String, and parts.effectivePolicyJSON: String (sorted-key JSON). Policy keys below
// follow the existing settings/config names; limits.agentTimeouts holds effective seconds per role.
// No criteria are source-, documentation-, or build-setup-only. No new declarations are needed
// to compile: incomplete policy records fail the assertions through the existing ledger API.
import Foundation
import Testing
@testable import AgentOSAdapters
@testable import AgentOSCore

@Suite struct GH_154Tests {
    @Test(arguments: [AgentRole.decomposer, .testAuthor, .implementer, .diagnoser])
    func everyRealRepoAgentRunRecordsAllEffectiveWorkSettingsAsSortedKeyJSON(role: AgentRole) async throws {
        let fixture = try Fixture(harness: Self.harness(), config: Self.config())
        defer { fixture.removeFiles() }
        let record = try await fixture.configuration(for: role)
        let policy = try Self.object(record.policy)

        try Self.expectPolicy(policy, effective: fixture.effective, config: fixture.config)
        #expect(try Self.hasSortedObjectKeys(record.policy), "Policy keys must be sorted at every nesting level.")
        #expect(!record.fingerprint.isEmpty)
    }

    @Test
    func theRecordUsesStricterRepoOverridesRatherThanHarnessDefaults() async throws {
        let fixture = try Fixture(harness: Self.harness(), config: Self.config())
        defer { fixture.removeFiles() }
        #expect(fixture.effective.problems.isEmpty)
        #expect(fixture.effective.policy.review.level == .agentAndHuman)
        #expect(fixture.effective.policy.guesswork == .ask)
        #expect(fixture.effective.policy.maxAttempts == 2)
        #expect(fixture.effective.policy.maxReworks == 1)
        #expect(fixture.effective.policy.maxAgentRuns == 7)
        #expect(fixture.effective.maxParallelAgents == 2)
        #expect(fixture.effective.policy.landingBatchSize == 3)
        #expect(fixture.effective.agentTimeouts["implementer"] == 900)

        let record = try await fixture.configuration(for: .implementer)
        try Self.expectPolicy(Self.object(record.policy), effective: fixture.effective, config: fixture.config)
    }

    @Test(arguments: ["reviewLevel", "landingBatchSize"])
    func otherwiseIdenticalSessionsGetDifferentFingerprintsWhenOneEffectiveSettingChanges(
        setting: String
    ) async throws {
        let config = Self.minimalConfig()
        var harness = HarnessSettings()
        let first = try Fixture(harness: harness, config: config)
        defer { first.removeFiles() }
        if setting == "reviewLevel" { harness.review.level = .agentAndHuman }
        else { harness.landingBatchSize = 1 }
        let second = try Fixture(harness: harness, config: config)
        defer { second.removeFiles() }

        let before = try await first.configuration(for: .implementer)
        let repeated = try await first.configuration(for: .implementer)
        let after = try await second.configuration(for: .implementer)
        #expect(before.fingerprint == repeated.fingerprint, "Run identifiers must not affect the fingerprint.")
        #expect(before.fingerprint != after.fingerprint, "Changing \(setting) must change the run fingerprint.")
        var changedPolicy = try Self.object(after.policy)
        let originalPolicy = try Self.object(before.policy)
        if setting == "reviewLevel" {
            var review = try Self.objectField("review", in: changedPolicy)
            #expect(review["level"] as? String == "agent+human")
            review["level"] = try Self.objectField("review", in: originalPolicy)["level"]
            changedPolicy["review"] = review
        } else {
            var limits = try Self.objectField("limits", in: changedPolicy)
            #expect(limits["landingBatchSize"] as? Int == 1)
            limits["landingBatchSize"] = try Self.objectField("limits", in: originalPolicy)["landingBatchSize"]
            changedPolicy["limits"] = limits
        }
        #expect(NSDictionary(dictionary: changedPolicy).isEqual(to: originalPolicy),
                "The sessions must differ in only the setting under test.")
    }

    @Test
    func policyKeyInsertionOrderDoesNotChangeTheRecordedPolicyOrFingerprint() async throws {
        var firstConfig = Self.config()
        var secondConfig = Self.config()
        firstConfig.review?.areas = Dictionary(uniqueKeysWithValues: [
            ("Sources/Zebra", "agent+human"), ("Sources/Alpha", "agent+human")
        ])
        secondConfig.review?.areas = Dictionary(uniqueKeysWithValues: [
            ("Sources/Alpha", "agent+human"), ("Sources/Zebra", "agent+human")
        ])
        firstConfig.agents?.timeouts = Dictionary(uniqueKeysWithValues: [
            ("reviewer", 780), ("implementer", 900), ("decomposer", 660)
        ])
        secondConfig.agents?.timeouts = Dictionary(uniqueKeysWithValues: [
            ("decomposer", 660), ("implementer", 900), ("reviewer", 780)
        ])
        let first = try Fixture(harness: Self.harness(), config: firstConfig)
        defer { first.removeFiles() }
        let second = try Fixture(harness: Self.harness(), config: secondConfig)
        defer { second.removeFiles() }

        let a = try await first.configuration(for: .testAuthor)
        let b = try await second.configuration(for: .testAuthor)
        #expect(NSDictionary(dictionary: try Self.object(a.policy)).isEqual(to: try Self.object(b.policy)))
        #expect(a.fingerprint == b.fingerprint)
        #expect(try Self.hasSortedObjectKeys(a.policy))
        #expect(try Self.hasSortedObjectKeys(b.policy))
    }

    @Test
    func aConfiguredGitHubAccountNeverAppearsInThePolicyAndDoesNotChangeItsFingerprint() async throws {
        let config = Self.config()
        let first = try Fixture(harness: Self.harness(), config: config)
        defer { first.removeFiles() }
        var settings = Self.harness()
        let account = "GH154-private-account-6a41"
        settings.githubAccount = account
        let second = try Fixture(harness: settings, config: config)
        defer { second.removeFiles() }
        #expect(second.effective.githubAccount == account, "The account must really be configured.")

        let a = try await first.configuration(for: .implementer)
        let b = try await second.configuration(for: .implementer)
        let policy = try Self.object(b.policy)
        #expect(!b.policy.contains(account))
        #expect(!Self.containsKey("githubAccount", in: policy))
        #expect(NSDictionary(dictionary: try Self.object(a.policy)).isEqual(to: policy))
        #expect(a.fingerprint == b.fingerprint, "Account identity is not an agent-work setting.")
    }

    @Test(arguments: ["prepare", "build", "test", "namedCheck"])
    func credentialsConfiguredInCheckCommandsAreNotRecorded(location: String) async throws {
        let token = "ghp_GH154_NOT_A_REAL_TOKEN_7284"
        let password = "GH154_NOT_A_REAL_PASSWORD_5319"
        let username = "GH154-private-command-account"
        let command = "GITHUB_TOKEN=\(token) checker --password=\(password) https://\(username):\(password)@example.invalid/check"
        var config = Self.config()
        switch location {
        case "prepare": config.build?.prepare = command
        case "build": config.build?.command = command
        case "test": config.test.command = command
        default: config.checks = [.init(name: "credential-bearing check", command: command)]
        }
        #expect(config.commands.contains(command), "The fake credentials must be part of actual configured commands.")
        let fixture = try Fixture(harness: Self.harness(), config: config)
        defer { fixture.removeFiles() }
        let record = try await fixture.configuration(for: .implementer)
        let policy = try Self.object(record.policy)
        #expect(!record.policy.contains(token))
        #expect(!record.policy.contains(password))
        #expect(!record.policy.contains(username))
        let recordedCommand: String?
        switch location {
        case "prepare": recordedCommand = try Self.objectField("build", in: policy)["prepare"] as? String
        case "build": recordedCommand = try Self.objectField("build", in: policy)["command"] as? String
        case "test": recordedCommand = try Self.objectField("test", in: policy)["command"] as? String
        default:
            let checks = try #require(policy["checks"] as? [[String: Any]])
            recordedCommand = checks.first { $0["name"] as? String == "credential-bearing check" }?["command"] as? String
        }
        let sanitized = try #require(recordedCommand, "Redaction must not drop the configured check.")
        #expect(sanitized.contains("checker"), "Keep the non-secret command so the recorded policy remains useful.")
    }

    @Test
    func theFixtureUsesTheExistingRunClaimAndTheJSONHelperRecognizesNestedKeyOrdering() async throws {
        let fixture = try Fixture(harness: HarnessSettings(), config: Self.minimalConfig())
        defer { fixture.removeFiles() }
        let run = "run-GH154-helper"
        let events = try await fixture.session.reconciler.agentRunStarted(run, .implementer)
        #expect(events.contains {
            if case .runStarted(let id, .implementer) = $0 { return id == run }
            return false
        })
        #expect(events.contains {
            if case .agentConfigured(let id, let settings) = $0 {
                return id == run && settings == AgentRunSettings(model: "GH154-model", effort: "high")
            }
            return false
        })
        #expect(try Self.hasSortedObjectKeys(Self.config().json))
        #expect(try Self.hasSortedObjectKeys(#"{"a":{"b":1,"c":"text with \"quotes\" and } braces"},"z":[{"a":1,"b":2}]}"#))
        #expect(try !Self.hasSortedObjectKeys(#"{"a":{"z":1,"b":2},"z":[]}"#))
        #expect(try !Self.hasSortedObjectKeys(#"{"z":1,"a":2}"#))
    }

    private static func harness() -> HarnessSettings {
        var settings = HarnessSettings()
        settings.maxAttempts = 5
        settings.maxReworks = 4
        settings.maxAgentRuns = 16
        settings.maxParallelAgents = 4
        settings.landingBatchSize = 6
        settings.guesswork = .autonomous
        settings.agentTimeouts = [
            "decomposer": 1320, "testAuthor": 1440, "implementer": 1560, "reviewer": 1680, "diagnoser": 720
        ]
        return settings
    }

    private static func minimalConfig() -> RepoConfig {
        RepoConfig(test: .init(command: "swift test", only: "--filter {suite}"),
                   leafTests: .init(target: "AcceptanceTests", folder: "Tests/AcceptanceTests"))
    }

    private static func config() -> RepoConfig {
        RepoConfig(
            build: .init(prepare: "xcodegen generate", command: "swift build"),
            test: .init(command: "swift test", only: "--filter {suite}"),
            checks: [.init(name: "lint", command: "swiftlint --strict"), .init(name: "format", command: "swift format lint")],
            leafTests: .init(target: "AcceptanceTests", folder: "Tests/AcceptanceTests", updatable: ["Tests/ExistingTests"]),
            limits: .init(maxAttempts: 2, maxReworks: 1, maxAgentRuns: 7, maxParallelAgents: 2, landingBatchSize: 3),
            agents: .init(deny: ["shell(rm)", "shell(curl)"], guesswork: "ask",
                          timeouts: ["decomposer": 660, "implementer": 900, "reviewer": 780]),
            protectedPaths: ["Secrets/", "release-settings.json"],
            review: .init(level: "agent+human", areas: ["Sources/Zebra": "agent+human", "Sources/Alpha": "agent+human"],
                          maxRounds: 3)
        )
    }

    private static func object(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private static func objectField(_ name: String, in object: [String: Any]) throws -> [String: Any] {
        try #require(object[name] as? [String: Any], "Recorded policy must include \(name).")
    }

    private static func expectPolicy(_ object: [String: Any], effective: EffectivePolicy, config: RepoConfig) throws {
        let review = try Self.objectField("review", in: object)
        #expect(review["level"] as? String == effective.policy.review.level.rawValue)
        #expect(review["areas"] as? [String: String] == effective.policy.review.areas.mapValues(\.rawValue))
        #expect(review["maxRounds"] as? Int == effective.policy.review.maxRounds)
        #expect(object["guesswork"] as? String == effective.policy.guesswork.rawValue)
        let limits = try Self.objectField("limits", in: object)
        #expect(limits["maxAttempts"] as? Int == effective.policy.maxAttempts)
        #expect(limits["maxReworks"] as? Int == effective.policy.maxReworks)
        #expect(limits["maxAgentRuns"] as? Int == effective.policy.maxAgentRuns)
        #expect(limits["maxParallelAgents"] as? Int == effective.maxParallelAgents)
        #expect(limits["landingBatchSize"] as? Int == effective.policy.landingBatchSize)
        #expect(limits["agentTimeouts"] as? [String: Int] == effective.agentTimeouts)
        let denied = try #require(object["deniedTools"] as? [String])
        let protected = try #require(object["protectedPaths"] as? [String])
        #expect(Set(denied) == Set(effective.deniedTools))
        #expect(Set(protected) == Set(effective.protectedPaths))
        let leafTests = try Self.objectField("leafTests", in: object)
        #expect(leafTests["target"] as? String == config.leafTests?.target)
        #expect(leafTests["folder"] as? String == config.leafTests?.folder)
        #expect(leafTests["updatable"] as? [String] == config.leafTests?.updatable)
        let build = try Self.objectField("build", in: object)
        #expect(build["prepare"] as? String == config.build?.prepare)
        #expect(build["command"] as? String == config.build?.command)
        let test = try Self.objectField("test", in: object)
        #expect(test["command"] as? String == config.test.command)
        #expect(test["only"] as? String == config.test.only)
        let checks = try #require(object["checks"] as? [[String: String]])
        #expect(checks == config.checks?.map { ["name": $0.name, "command": $0.command] })
    }

    private static func containsKey(_ key: String, in value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return object[key] != nil || object.values.contains { Self.containsKey(key, in: $0) }
        }
        if let array = value as? [Any] { return array.contains { Self.containsKey(key, in: $0) } }
        return false
    }

    private static func hasSortedObjectKeys(_ json: String) throws -> Bool {
        _ = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let characters = Array(json)
        var objects: [[String]] = []
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "{": objects.append([])
            case "}":
                let lastObject = objects.popLast()
                let keys = try #require(lastObject)
                if keys != keys.sorted() { return false }
            case "\"":
                let start = index
                index += 1
                while index < characters.count {
                    if characters[index] == "\\" { index += 2; continue }
                    if characters[index] == "\"" { break }
                    index += 1
                }
                let end = index
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == ":" {
                    let key = try JSONDecoder().decode(
                        String.self, from: Data(String(characters[start...end]).utf8)
                    )
                    let current = try #require(objects.indices.last)
                    objects[current].append(key)
                }
            default: break
            }
            index += 1
        }
        return objects.isEmpty
    }

    private struct Configuration {
        let policy: String
        let fingerprint: String
    }

    private struct Fixture {
        let root: URL
        let config: RepoConfig
        let effective: EffectivePolicy
        let ledger: Ledger
        let session: RepositorySession

        init(harness: HarnessSettings, config: RepoConfig) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH154-\(UUID())")
            self.config = config
            effective = EffectivePolicy.resolve(harness: harness, repo: config, defaultBranch: "main")
            ledger = try Ledger()
            var team = AgentTeam(name: "GH154", decomposer: UnusedAgent(), testAuthor: UnusedAgent(), implementer: UnusedAgent())
            team.runSettings = { _ in AgentRunSettings(model: "GH154-model", effort: "high") }
            session = try RepositorySession(
                location: RepositoryLocation(root: root, identity: "GH154", branch: "main", commit: "fixed-repo-tip"),
                storage: root.appending(path: "storage"), ledger: ledger, config: config, policy: effective, team: team
            )
        }

        func configuration(for role: AgentRole) async throws -> Configuration {
            let run = "run-GH154-\(UUID())"
            let claim = try await session.reconciler.agentRunStarted(run, role)
            try await ledger.append(claim.map { LedgerEvent(node: nil, by: .reconciler, kind: $0) })
            let records = await ledger.allRecords()
            var matches: [Configuration] = []
            for record in records {
                guard case .runConfigurationRecorded(let id, let fingerprint, let parts) = record.event.kind,
                      id == run else { continue }
                matches.append(Configuration(policy: parts.effectivePolicyJSON, fingerprint: fingerprint))
            }
            #expect(matches.count == 1, "Each real-repo run claim must record exactly one configuration for that run.")
            return try #require(matches.first, "The real-repo run has no recorded configuration.")
        }

        func removeFiles() {
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove GH154 fixture: \(error)") }
        }
    }

    private struct UnusedAgent: Decomposer, TestAuthor, Implementer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown { Breakdown(children: []) }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport { AgentReport() }
        func implement(_ task: AgentTask) async throws -> AgentReport { AgentReport() }
    }
}
