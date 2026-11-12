// Expected API: HarnessViewModel.selectRepoConfigOverride(_:) merges a full-path JSON fragment
// into the displayed creation draft, or exposes a merge snippet and instructions for an existing config.
// configDraftExplanation explains incomplete drafts. openRepoConfig(prepare:open:) is the explicit
// create/open boundary; it passes the current draft to the adapter and exposes failures in repoConfigFileError.
import Foundation
import Testing
import AgentOSCore
import AgentOSUI
@testable import AgentOSAdapters

@Suite struct GH_56Tests {
    @Test @MainActor
    func choicesCoexistAndChangingOnePreservesCommandsSiblingModelsAndOtherDraftContent() throws {
        let model = HarnessViewModel()
        model.configDraft = Self.completeDraft
        let actions = Actions()
        model.actions = actions

        for fragment in [
            #"{"agents":{"guesswork":"ask"}}"#,
            #"{"limits":{"maxAttempts":2}}"#,
            #"{"limits":{"maxReworks":1}}"#,
            #"{"limits":{"maxParallelAgents":1}}"#,
            #"{"agents":{"models":{"decomposer":"model-a"}}}"#,
            #"{"agents":{"models":{"testAuthor":"model-b"}}}"#,
            #"{"agents":{"models":{"implementer":"model-a"}}}"#,
            #"{"signals":{"disable":["go","build"]}}"#,
            #"{"limits":{"maxAttempts":1}}"#,
            #"{"agents":{"models":{"implementer":"model-b"}}}"#,
            #"{"signals":{"disable":["go"]}}"#,
        ] {
            try model.selectRepoConfigOverride(fragment)
        }

        let draft = try #require(model.configDraft)
        let parsed = try RepoConfig.parse(draft)
        var expected = try RepoConfig.parse(Self.completeDraft).config
        expected.agents?.guesswork = "ask"
        expected.agents?.models = AgentModels(decomposer: "model-a", testAuthor: "model-b", implementer: "model-b")
        expected.limits = .init(maxAttempts: 1, maxReworks: 1, maxParallelAgents: 1)
        expected.signals = .init(disable: ["go"])
        try Self.expectSameJSON(draft, expected.json)
        #expect(parsed.unknownKeys.isEmpty)
        #expect(model.config == nil, "A selection is not a loaded repo config.")
        #expect(actions.openRequests == 0)
        #expect(actions.rescanRequests == 0)
    }

    @Test @MainActor
    func selectionsAreAddedToTheActualScannerDraftRatherThanReplacingItsInferences() throws {
        let assessment = ReadinessRules.assess(Self.snapshot(), harness: Self.harness, baseline: nil)
        let inferred = try #require(assessment.draft)
        let model = HarnessViewModel()
        model.configDraft = inferred.json

        try model.selectRepoConfigOverride(#"{"agents":{"guesswork":"ask"}}"#)
        try model.selectRepoConfigOverride(#"{"agents":{"models":{"implementer":"model-b"}}}"#)
        let selected = try RepoConfig.parse(#require(model.configDraft)).config
        var expected = inferred
        expected.agents = .init(models: AgentModels(implementer: "model-b"), guesswork: "ask")
        #expect(selected == expected)
        #expect(selected.test.command == "swift test")
        #expect(selected.test.only == "--filter {suite}")
        #expect(selected.leafTests == .init(target: "AppTests", folder: "Tests/AppTests"))
    }

    @Test @MainActor
    func anUninferableRepoShowsOverrideOnlyJSONAndExplainsTheMissingRequiredCommand() throws {
        let repo = RepositorySnapshot(branch: "main", commit: "no-commands", files: ["README.md"],
                                      contents: ["README.md": "# A repo with no known build system"])
        let assessment = ReadinessRules.assess(repo, harness: Self.harness, baseline: nil)
        #expect(assessment.draft == nil)
        let model = HarnessViewModel()
        model.configDraft = assessment.draft?.json

        try model.selectRepoConfigOverride(#"{"agents":{"guesswork":"ask"}}"#)
        try model.selectRepoConfigOverride(#"{"limits":{"maxAttempts":1}}"#)
        let draft = try #require(model.configDraft)
        try Self.expectSameJSON(draft, #"{"agents":{"guesswork":"ask"},"limits":{"maxAttempts":1}}"#)
        let explanation = try #require(model.configDraftExplanation).lowercased()
        #expect(explanation.contains("test.command"))
        #expect(explanation.contains("required"))
        #expect(explanation.contains("load"))
        #expect(throws: RepoConfig.ParseError.self) { try RepoConfig.parse(draft) }
        #expect(model.config == nil)
    }

    @Test @MainActor
    func openingPolicySelectingAndReadingCopyableSnippetsDoNotRequestCreation() async throws {
        let model = HarnessViewModel()
        let actions = Actions()
        model.actions = actions
        model.configDraft = Self.completeDraft
        model.readiness = ReadinessScan(branch: "main", commit: "before", findings: [])
        model.policy = EffectivePolicy.resolve(harness: Self.harness, repo: nil, defaultBranch: "main")
        _ = PolicyPane()
        _ = model.configDraft

        try model.selectRepoConfigOverride(#"{"limits":{"maxAttempts":1}}"#)
        let copyable = try #require(model.repoConfigOverrideSnippet)
        try Self.expectSameJSON(copyable, #"{"limits":{"maxAttempts":1}}"#)
        _ = model.configDraft
        await model.rescan()

        #expect(actions.rescanRequests == 1)
        #expect(actions.openRequests == 0, "Only the explicit Create/Open action may request file preparation.")
        model.openRepoConfig()
        #expect(actions.openRequests == 1)
    }

    @Test @MainActor
    func existingConfigSelectionsOnlyExposeAMergeFragmentAndCommitRescanInstructions() throws {
        let model = HarnessViewModel()
        let original = try RepoConfig.parse(Self.completeDraft).config
        model.config = original
        model.configDraft = nil
        model.readiness = ReadinessScan(branch: "develop", commit: "existing", findings: [])
        let actions = Actions()
        model.actions = actions

        try model.selectRepoConfigOverride(#"{"agents":{"guesswork":"ask"}}"#)
        try Self.expectSameJSON(#require(model.repoConfigOverrideSnippet), #"{"agents":{"guesswork":"ask"}}"#)
        try model.selectRepoConfigOverride(#"{"agents":{"models":{"implementer":"model-b"}}}"#)
        try Self.expectSameJSON(#require(model.repoConfigOverrideSnippet),
                                #"{"agents":{"models":{"implementer":"model-b"}}}"#)
        let instructions = try #require(model.repoConfigOverrideInstructions).lowercased()
        #expect(instructions.contains("sibling"))
        #expect(instructions.contains("preserv"))
        #expect(instructions.contains("commit"))
        #expect(instructions.contains("develop"), "Instructions must name this repo's default branch, not hard-code main.")
        #expect(instructions.contains("rescan"))
        #expect(model.config == original)
        #expect(model.configDraft == nil)
        #expect(actions.openRequests == 0)
    }

    @Test @MainActor
    func explicitCreationPassesTheLatestDisplayedDraftToPreparationAndOpensItsResult() throws {
        let model = HarnessViewModel()
        model.configDraft = Self.completeDraft
        try model.selectRepoConfigOverride(#"{"agents":{"models":{"implementer":"model-b"}}}"#)
        try model.selectRepoConfigOverride(#"{"limits":{"maxAttempts":1}}"#)
        let displayed = try #require(model.configDraft)
        let file = URL(fileURLWithPath: "/not-accessed/checkout/.agentos/config.json")
        var preparedDraft: String?
        var preparations = 0
        var opened: [URL] = []

        model.openRepoConfig(prepare: { draft in
            preparations += 1
            preparedDraft = draft
            return file
        }, open: { opened.append($0) })

        #expect(preparations == 1)
        try Self.expectSameJSON(#require(preparedDraft), displayed)
        #expect(opened == [file])
        #expect(model.repoConfigFileError == nil)
    }

    @Test @MainActor
    func failedExplicitCreationReportsTheFailureWithoutOpeningOrLosingTheDraft() throws {
        let model = HarnessViewModel()
        model.configDraft = Self.completeDraft
        try model.selectRepoConfigOverride(#"{"limits":{"maxAttempts":1}}"#)
        let draft = try #require(model.configDraft)
        var opened = false
        model.openRepoConfig(prepare: { _ in
            throw CreationFailure()
        }, open: { _ in opened = true })

        let message = try #require(model.repoConfigFileError)
        #expect(message.contains(RepoConfig.path))
        #expect(message.contains("fixture write denied"), "The underlying write failure must remain visible.")
        #expect(!opened)
        try Self.expectSameJSON(#require(model.configDraft), draft)
    }

    @Test
    func explicitFilePreparationWritesTheSelectedDraftOnlyToTheMissingCheckoutFile() throws {
        let root = try Self.temporaryDirectory()
        defer { Self.removeFixture(root) }
        let destination = AgentOSAdapters.RepoConfigFile.url(in: root)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let selected = #"{"test":{"command":"swift test"},"agents":{"guesswork":"ask"},"limits":{"maxAttempts":1}}"#

        let created = try AgentOSAdapters.RepoConfigFile.prepare(in: root, draft: selected)
        #expect(created.created)
        #expect(created.url == destination)
        try Self.expectSameJSON(String(contentsOf: created.url, encoding: .utf8), selected)
        #expect(try RepoConfig.parse(String(contentsOf: created.url, encoding: .utf8)).config.agents?.guesswork == "ask")
    }

    @Test(arguments: [false, true]) @MainActor
    func createOrOpenPreservesAnExistingCheckoutFileByteForByte(committedConfigExists: Bool) throws {
        let root = try Self.temporaryDirectory()
        defer { Self.removeFixture(root) }
        let destination = AgentOSAdapters.RepoConfigFile.url(in: root)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ \"test\" : { \"command\" : \"my hand-edited tests\" }, \"custom\" : true }\r\n".utf8)
        try original.write(to: destination)
        let model = HarnessViewModel()
        model.config = committedConfigExists ? try RepoConfig.parse(Self.completeDraft).config : nil
        model.configDraft = committedConfigExists ? nil : Self.completeDraft
        try model.selectRepoConfigOverride(#"{"limits":{"maxAttempts":1}}"#)
        var opened: [URL] = []
        var created: Bool?

        model.openRepoConfig(prepare: { draft in
            let result = try AgentOSAdapters.RepoConfigFile.prepare(in: root, draft: draft)
            created = result.created
            return result.url
        }, open: { opened.append($0) })

        #expect(created == false)
        #expect(opened == [destination])
        #expect(try Data(contentsOf: destination) == original)
        #expect(model.repoConfigFileError == nil)
    }

    @Test @MainActor
    func actualWriteFailuresRemainVisibleAtTheCreateOpenBoundary() throws {
        let root = try Self.temporaryDirectory()
        defer { Self.removeFixture(root) }
        let blockedParent = root.appending(path: ".agentos")
        let original = Data("a regular file, not a directory".utf8)
        try original.write(to: blockedParent)
        let model = HarnessViewModel()
        model.configDraft = Self.completeDraft
        var opened = false

        model.openRepoConfig(prepare: { draft in
            try AgentOSAdapters.RepoConfigFile.prepare(in: root, draft: draft).url
        }, open: { _ in opened = true })

        #expect(try #require(model.repoConfigFileError).contains(RepoConfig.path))
        #expect(!opened)
        #expect(try Data(contentsOf: blockedParent) == original)
    }

    @Test(arguments: [false, true])
    func rescanningNeverCreatesOrModifiesTheCheckoutConfig(existingCheckoutFile: Bool) async throws {
        let root = try await Self.makeRepository()
        defer { Self.removeFixture(root) }
        let destination = AgentOSAdapters.RepoConfigFile.url(in: root)
        let original = Data("{ \"agents\" : { \"guesswork\" : \"ask\" } }\r\n".utf8)
        if existingCheckoutFile {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: destination)
        }

        for _ in 0..<2 {
            let result = await ReadinessScanner().scan(root, harness: Self.harness)
            #expect(result.config == nil, "An uncommitted checkout config is not the config on the default branch.")
            if existingCheckoutFile {
                #expect(try Data(contentsOf: destination) == original)
            } else {
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                #expect(!FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
            }
        }
    }

    @Test @MainActor
    func anExplicitlyCreatedSelectedDraftLoadsAfterCommitAndRescanWithRepoAttributedValues() async throws {
        let root = try await Self.makeRepository()
        defer { Self.removeFixture(root) }
        let scanner = ReadinessScanner()
        let initial = await scanner.scan(root, harness: Self.harness)
        let model = HarnessViewModel()
        model.configDraft = try #require(initial.draft)
        for fragment in Self.selectedFragments {
            try model.selectRepoConfigOverride(fragment)
        }
        let displayed = try #require(model.configDraft)
        let created = try AgentOSAdapters.RepoConfigFile.prepare(in: root, draft: displayed)
        #expect(created.created)
        let beforeCommit = await scanner.scan(root, harness: Self.harness)
        #expect(beforeCommit.config == nil)
        #expect(beforeCommit.scan.findings.contains { $0.check == "checkout.config" })

        try await Self.commitConfig(in: root)
        let rescanned = await scanner.scan(root, harness: Self.harness)
        try Self.expectChosenPolicy(rescanned)
        try Self.expectSameJSON(try #require(rescanned.config).json, displayed)
        model.config = rescanned.config
        model.policy = rescanned.policy
        #expect(model.policy == rescanned.policy)
    }

    @Test
    func manuallyMergedOverridesLoadAfterDefaultBranchCommitAndRescanWithoutLosingSiblings() async throws {
        let root = try await Self.makeRepository()
        defer { Self.removeFixture(root) }
        // This is a human's merge, including settings the override snippets must not discard.
        var merged = try RepoConfig.parse(Self.completeDraft).config
        merged.agents?.guesswork = "ask"
        merged.agents?.models = AgentModels(decomposer: "model-a", testAuthor: "model-b", implementer: "model-b")
        merged.limits = .init(maxAttempts: 1, maxReworks: 1, maxParallelAgents: 1)
        merged.signals = .init(disable: ["go"])
        let file = AgentOSAdapters.RepoConfigFile.url(in: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try merged.json.write(to: file, atomically: true, encoding: .utf8)
        try await Self.commitConfig(in: root)

        let rescanned = await ReadinessScanner().scan(root, harness: Self.harness)
        try Self.expectChosenPolicy(rescanned)
        #expect(rescanned.config == merged)
        #expect(rescanned.policy.deniedTools.contains("custom-tool"))
        #expect(rescanned.policy.protectedPaths.contains("Secrets/"))
    }

    @Test
    func explicitlyChoosingTheHarnessValueShowsRepoForGuessworkAndLimitsAndHarnessForModels() throws {
        var config = try RepoConfig.parse(Self.completeDraft).config
        config.agents?.guesswork = Self.harness.guesswork.rawValue
        config.agents?.models = Self.harness.models
        config.limits = .init(maxAttempts: Self.harness.maxAttempts, maxReworks: Self.harness.maxReworks,
                              maxParallelAgents: Self.harness.maxParallelAgents)
        let policy = EffectivePolicy.resolve(harness: Self.harness, repo: config, defaultBranch: "main")
        // An explicit repo value is attributed to the repo even when it equals the harness value (GH-54).
        for name in ["Guesswork", "Max attempts per leaf", "Max reworks per leaf", "Max parallel agents"] {
            let row = try #require(policy.settings.first { $0.name == name })
            #expect(row.source == .repo)
            #expect(row.note == nil)
        }
        for name in ["Breakdown agent", "Acceptance tests agent", "Implementation agent"] {
            let row = try #require(policy.settings.first { $0.name == name })
            #expect(row.source == .harness)
            #expect(row.note == nil)
        }
    }

    private static let completeDraft = #"""
        {
          "build": {"prepare": "echo prepare", "command": "echo build"},
          "test": {"command": "swift test", "only": "--filter {suite}"},
          "checks": [{"name": "lint", "command": "echo lint"}],
          "leafTests": {"target": "AppTests", "folder": "Tests/AppTests"},
          "components": ["Sources/App"],
          "landing": {"branch": "agentos/main"},
          "agents": {"deny": ["custom-tool"], "context": ["README.md"], "models": {"testAuthor": "model-a"}},
          "protectedPaths": ["Secrets/"],
          "tracker": {"type": "local"}
        }
        """#

    private static let selectedFragments = [
        #"{"agents":{"guesswork":"ask"}}"#,
        #"{"agents":{"models":{"decomposer":"model-a"}}}"#,
        #"{"agents":{"models":{"testAuthor":"model-b"}}}"#,
        #"{"agents":{"models":{"implementer":"model-b"}}}"#,
        #"{"limits":{"maxAttempts":1}}"#,
        #"{"limits":{"maxReworks":1}}"#,
        #"{"limits":{"maxParallelAgents":1}}"#,
        #"{"signals":{"disable":["go"]}}"#,
    ]

    private static var harness: HarnessSettings {
        var settings = HarnessSettings()
        settings.offeredModels = ["model-a", "model-b"]
        return settings
    }

    private static func snapshot() -> RepositorySnapshot {
        let contents = [
            "README.md": "# App",
            "Package.swift": #"targets: [.target(name: "App"), .testTarget(name: "AppTests")]"#,
            "Sources/App/App.swift": "struct App {}",
            "Tests/AppTests/AppTests.swift": "import Testing\n@Test func example() {}",
        ]
        return RepositorySnapshot(branch: "main", commit: "initial", files: Array(contents.keys), contents: contents)
    }

    private static func expectSameJSON(_ actual: String, _ expected: String) throws {
        let actualObject = try #require(JSONSerialization.jsonObject(with: Data(actual.utf8)) as? [String: Any])
        let expectedObject = try #require(JSONSerialization.jsonObject(with: Data(expected.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: actualObject).isEqual(to: expectedObject))
    }

    private static func expectChosenPolicy(_ scanned: ScannedRepository) throws {
        #expect(scanned.scan.branch == "main")
        #expect(scanned.config != nil)
        #expect(scanned.policy.problems.isEmpty)
        #expect(!scanned.scan.findings.contains {
            ($0.check.hasPrefix("config") || $0.check == "checkout.config") && $0.severity != .info
        })
        #expect(scanned.policy.policy.guesswork == .ask)
        #expect(scanned.policy.policy.maxAttempts == 1)
        #expect(scanned.policy.policy.maxReworks == 1)
        #expect(scanned.policy.maxParallelAgents == 1)
        #expect(scanned.policy.agentModels == AgentModels(decomposer: "model-a", testAuthor: "model-b", implementer: "model-b"))
        #expect(scanned.policy.policy.allowedSignals == harness.offeredSignals.subtracting([.go]))
        for name in ["Guesswork", "Max attempts per leaf", "Max reworks per leaf", "Max parallel agents",
                     "Breakdown agent", "Acceptance tests agent", "Implementation agent", "Signals"] {
            let row = try #require(scanned.policy.settings.first { $0.name == name })
            #expect(row.source == .repo)
            #expect(row.note == nil)
        }
        for name in ["Max attempts per leaf", "Max reworks per leaf", "Max parallel agents"] {
            #expect(scanned.policy.settings.first { $0.name == name }?.value == "1")
        }
        #expect(scanned.policy.settings.first { $0.name == "Guesswork" }?.value.contains("ask") == true)
        for (name, value) in [("Breakdown agent", "model-a"), ("Acceptance tests agent", "model-b"),
                              ("Implementation agent", "model-b")] {
            #expect(scanned.policy.settings.first { $0.name == name }?.value.contains(value) == true)
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "agentos-GH-56-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func removeFixture(_ root: URL) {
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Couldn't remove GH-56 fixture \(root.path): \(error)")
        }
    }

    private static func makeRepository() async throws -> URL {
        let root = try temporaryDirectory()
        do {
            for (path, text) in snapshot().contents {
                let file = root.appending(path: path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            try await git(["init", "-q", "-b", "main"], in: root)
            try await git(["add", "."], in: root)
            try await git(["-c", "user.name=GH56", "-c", "user.email=gh56@example.invalid",
                           "commit", "-q", "-m", "Initial fixture"], in: root)
            return root
        } catch {
            removeFixture(root)
            throw error
        }
    }

    private static func commitConfig(in root: URL) async throws {
        try await git(["add", "--", RepoConfig.path], in: root)
        try await git(["-c", "user.name=GH56", "-c", "user.email=gh56@example.invalid",
                       "commit", "-q", "-m", "Choose repo overrides"], in: root)
    }

    private static func git(_ arguments: [String], in root: URL) async throws {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: root)
        try #require(result.status == 0, "\(result.output)")
    }

    private struct CreationFailure: Error, CustomStringConvertible {
        var description: String { "fixture write denied" }
    }

    @MainActor private final class Actions: HarnessActions {
        var openRequests = 0
        var rescanRequests = 0

        func openRepoConfig() { openRequests += 1 }
        func rescan() async { rescanRequests += 1 }
        func stopRun(node: NodeID, run: RunID, by person: String) async {}
        func addLabel(_ name: String, to key: String) async {}
        func removeLabel(_ name: String, from key: String) async {}
        func comment(_ text: String, on key: String) async {}
        func createTicket(title: String, description: String, criteria: [String], blockedBy: [String]) async {}
        func edit(_ key: String, title: String, description: String, criteria: [String], blockedBy: [String]) async {}
        func verifyChain() async {}
        func open(_ path: String) {}
    }
}
