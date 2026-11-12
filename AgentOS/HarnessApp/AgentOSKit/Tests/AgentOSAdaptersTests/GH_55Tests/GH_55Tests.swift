// API contract: EffectivePolicy exposes model/signal override row metadata and validated JSON fragments,
// backed by RepoOverrideDefinitions shared with resolution. PolicyPane uses these rows and the
// @MainActor PolicyOverrideEditor selection/Copy API; copying accepts an isolated NSPasteboard.

import AgentOSCore
import AgentOSUI
import AppKit
import Foundation
import Testing

@Suite
struct GH_55Tests {
    @Test(arguments: AgentModels.roles)
    func agentRowsOfferOverridesAndSeparateTheExactModelFromProviderAndRole(
        role: AgentOSCore.AgentRole
    ) throws {
        let harness = harnessSettings()
        var repo = validConfig()
        var models = AgentModels()
        models[role] = "vendor/alternative-2026.11"
        repo.agents = .init(models: models)
        let policy = resolve(harness, repo)

        let row = try #require(policy.modelOverride(for: role))
        #expect(row.actionTitle == "Override in repo config…")
        #expect(row.keyPath == "agents.models.\(role.rawValue)")
        #expect(row.provider == HarnessSettings.agentProvider)
        #expect(row.modelIdentifier == "vendor/alternative-2026.11")
        #expect(row.modelIdentifier != row.provider)
        #expect(row.modelIdentifier != role.job)
        #expect(row.inheritanceExplanation == nil)
        #expect(try modelSetting(policy, role).source == .repo)
    }

    @Test(arguments: AgentModels.roles)
    func modelChoicesContainOnlyTheRolesHarnessModelAndDistinctOfferedAlternatives(
        role: AgentOSCore.AgentRole
    ) throws {
        var harness = harnessSettings()
        let ownModel = try #require(harness.models[role])
        let otherRoleModels = Set(AgentModels.roles.filter { $0 != role }.compactMap { harness.models[$0] })
        harness.offeredModels = ["vendor/alternative-2026.11", ownModel, "vendor/alternative-2026.11"]
        let policy = resolve(harness)
        let row = try #require(policy.modelOverride(for: role))

        #expect(Set(row.choices) == [ownModel, "vendor/alternative-2026.11"])
        #expect(row.choices.count == Set(row.choices).count)
        #expect(Set(row.choices).isDisjoint(with: otherRoleModels))
        #expect(row.choices == RepoOverrideDefinitions.modelChoices(for: role, harness: harness))
        #expect(!row.choices.contains("vendor/not-offered"))
    }

    @Test(arguments: AgentModels.roles)
    func noOfferedModelsAndAnInheritedCLIDefaultOfferNoInventedIdentifier(
        role: AgentOSCore.AgentRole
    ) throws {
        let harness = HarnessSettings()
        let policy = resolve(harness)
        let row = try #require(policy.modelOverride(for: role))

        #expect(row.actionTitle == "Override in repo config…")
        #expect(row.modelIdentifier == nil)
        #expect(row.choices.isEmpty)
        let explanation = try #require(row.inheritanceExplanation).lowercased()
        #expect(explanation.contains("cli"))
        #expect(explanation.contains("default"))
        #expect(policy.agentModels[role] == nil)
        #expect(try modelSetting(policy, role).source == .harness)
        #expect(throws: (any Error).self) {
            try policy.modelFragment(for: role, identifier: "default model")
        }
    }

    @Test(arguments: AgentModels.roles)
    func anInheritedCLIDefaultStillAllowsConcreteHarnessOfferedAlternatives(
        role: AgentOSCore.AgentRole
    ) throws {
        var harness = HarnessSettings()
        harness.offeredModels = ["vendor/alternative-2026.11", "vendor/alternative-2026.11"]
        let policy = resolve(harness)
        let row = try #require(policy.modelOverride(for: role))
        #expect(row.modelIdentifier == nil)
        #expect(row.inheritanceExplanation != nil)
        #expect(row.choices == ["vendor/alternative-2026.11"])

        let fragment = try policy.modelFragment(for: role, identifier: "vendor/alternative-2026.11")
        try expectModelFragment(fragment, role: role, identifier: "vendor/alternative-2026.11")
        let effective = resolve(harness, try merging(fragment, into: validConfig()))
        #expect(effective.problems.isEmpty)
        #expect(effective.agentModels[role] == "vendor/alternative-2026.11")
        #expect(try modelSetting(effective, role).source == .repo)
    }

    @Test(arguments: AgentModels.roles)
    func aConcreteHarnessModelIsStillSelectableWhenNoAlternativesAreOffered(
        role: AgentOSCore.AgentRole
    ) throws {
        var harness = harnessSettings()
        harness.offeredModels = []
        let identifier = try #require(harness.models[role])
        let policy = resolve(harness)
        let row = try #require(policy.modelOverride(for: role))

        #expect(row.choices == [identifier])
        let fragment = try policy.modelFragment(for: role, identifier: identifier)
        try expectModelFragment(fragment, role: role, identifier: identifier)
        let merged = try merging(fragment, into: validConfig())
        let effective = resolve(harness, merged)
        #expect(effective.problems.isEmpty)
        #expect(effective.agentModels[role] == identifier)
        #expect(try modelSetting(effective, role).source == .repo)
    }

    @Test(arguments: AgentModels.roles)
    func everyOfferedModelFragmentRoundTripsAtItsExactRolePath(
        role: AgentOSCore.AgentRole
    ) throws {
        let harness = harnessSettings()
        let policy = resolve(harness)
        let row = try #require(policy.modelOverride(for: role))
        let expected = Set([try #require(harness.models[role])] + harness.offeredModels)
        #expect(Set(row.choices) == expected)

        for identifier in row.choices {
            let fragment = try policy.modelFragment(for: role, identifier: identifier)
            try expectModelFragment(fragment, role: role, identifier: identifier)
            var base = validConfig()
            base.agents = .init(deny: ["custom-denied-tool"], guesswork: "ask", context: ["README.md"])
            base.signals = .init(disable: ["go"])
            let merged = try merging(fragment, into: base)
            let effective = resolve(harness, merged)

            #expect(effective.problems.isEmpty)
            #expect(effective.agentModels[role] == identifier)
            #expect(try modelSetting(effective, role).source == .repo)
            #expect(merged.agents?.deny == base.agents?.deny)
            #expect(merged.agents?.guesswork == "ask")
            #expect(merged.agents?.context == ["README.md"])
            #expect(merged.signals == base.signals)
            #expect(merged.test == base.test)
        }
    }

    @Test(arguments: AgentModels.roles)
    func explicitHarnessModelEqualityIsRepoSourcedButMissingAndNullAreInherited(
        role: AgentOSCore.AgentRole
    ) throws {
        let harness = harnessSettings()
        let identifier = try #require(harness.models[role])
        var repo = validConfig()
        var models = AgentModels()
        models[role] = identifier
        repo.agents = .init(models: models)
        let explicit = resolve(harness, repo)
        #expect(explicit.problems.isEmpty)
        #expect(try modelSetting(explicit, role).source == .repo)

        let inheritedConfigs = [
            #"{"test":{"command":"swift test"}}"#,
            #"{"test":{"command":"swift test"},"agents":{"models":null}}"#,
            """
            {"test":{"command":"swift test"},"agents":{"models":{"\(role.rawValue)":null}}}
            """,
        ]
        for json in inheritedConfigs {
            let parsed = try RepoConfig.parse(json)
            let inherited = resolve(harness, parsed.config)
            #expect(inherited.problems.isEmpty)
            #expect(inherited.agentModels[role] == identifier)
            #expect(try modelSetting(inherited, role).source == .harness)
            #expect(try #require(inherited.modelOverride(for: role)).modelIdentifier == identifier)
        }
    }

    @Test(arguments: AgentModels.roles)
    func unofferedModelsAreNeitherChoicesNorAcceptedOverrides(
        role: AgentOSCore.AgentRole
    ) throws {
        let harness = harnessSettings()
        let policy = resolve(harness)
        let rejected = "vendor/not-offered"
        let row = try #require(policy.modelOverride(for: role))
        #expect(!row.choices.contains(rejected))
        #expect(throws: (any Error).self) {
            try policy.modelFragment(for: role, identifier: rejected)
        }

        var repo = validConfig()
        var models = AgentModels()
        models[role] = rejected
        repo.agents = .init(models: models)
        let effective = resolve(harness, repo)
        #expect(!effective.problems.isEmpty)
        #expect(effective.agentModels[role] == harness.models[role])
        #expect(try modelSetting(effective, role).source == .harness)
    }

    @Test
    func signalsRowSeparatesEnabledSignalsFromExistingRawDisableTokens() {
        var harness = harnessSettings()
        harness.offeredSignals = [.preview, .build, .go, .retry]
        var repo = validConfig()
        repo.signals = .init(disable: ["harness:go", "retry"])
        let policy = resolve(harness, repo)
        let row = policy.signalOverride

        #expect(row.actionTitle == "Override in repo config…")
        #expect(row.keyPath == "signals.disable")
        #expect(row.enabledSignals == [.preview, .build])
        #expect(row.enabledSignals == policy.policy.allowedSignals)
        #expect(Set(row.disabledTokens) == ["harness:go", "retry"])
        #expect(Set(row.choices) == harness.offeredSignals)
        #expect(row.choices.count == Set(row.choices).count)
        #expect(row.choices == RepoOverrideDefinitions.signalChoices(harness: harness))
    }

    @Test
    func everySignalSelectionPreservesExistingDisabledTokensAndResolvesTheSelectedSet() throws {
        var harness = harnessSettings()
        harness.offeredSignals = [.preview, .build, .retry, .go]
        var repo = validConfig()
        repo.signals = .init(disable: ["harness:go", "replan"])
        let policy = resolve(harness, repo)
        let selectable: [HarnessCommand] = [.preview, .build, .retry]

        for mask in 0..<(1 << selectable.count) {
            let selected = Set(selectable.enumerated().compactMap { index, command in
                mask & (1 << index) == 0 ? nil : command
            })
            let fragment = try policy.signalsFragment(disabling: selected)
            let tokens = try disabledTokens(in: fragment)
            #expect(Set(tokens) == Set(["harness:go", "replan"] + selected.map(\.rawValue)))
            #expect(tokens.count == Set(tokens).count)
            let merged = try merging(fragment, into: repo)
            let effective = resolve(harness, merged)

            #expect(effective.problems.isEmpty)
            #expect(effective.policy.allowedSignals == harness.offeredSignals.subtracting(selected.union([.go])))
            #expect(effective.settings.first { $0.name == "Signals" }?.source == .repo)
            #expect(merged.test == repo.test)
        }
    }

    @Test
    func signalDefinitionsAndPolicyResolutionRecognizeTheSameRawTokens() throws {
        let harness = HarnessSettings()
        let policy = resolve(harness)
        let tokens = RepoOverrideDefinitions.knownSignalTokens
        #expect(Set(tokens) == Set(HarnessCommand.allCases.map(\.rawValue)))
        #expect(tokens.count == Set(tokens).count)
        #expect(Set(policy.signalOverride.choices) == Set(HarnessCommand.allCases))

        for command in policy.signalOverride.choices {
            let fragment = try policy.signalsFragment(disabling: [command])
            #expect(try disabledTokens(in: fragment) == [command.rawValue])
            let merged = try merging(fragment, into: validConfig())
            let effective = resolve(harness, merged)
            #expect(effective.problems.isEmpty)
            #expect(effective.policy.allowedSignals == harness.offeredSignals.subtracting([command]))
        }
    }

    @Test
    func harnessDisabledSignalsCannotBeOfferedOrEnabledByAnOverride() throws {
        var harness = harnessSettings()
        harness.offeredSignals = [.preview, .build]
        let policy = resolve(harness)
        #expect(Set(policy.signalOverride.choices) == [.preview, .build])
        #expect(!policy.signalOverride.choices.contains(.go))
        #expect(throws: (any Error).self) {
            try policy.signalsFragment(disabling: [.go])
        }

        for selection: Set<HarnessCommand> in [[], [.preview], [.build], [.preview, .build]] {
            let fragment = try policy.signalsFragment(disabling: selection)
            let effective = resolve(harness, try merging(fragment, into: validConfig()))
            #expect(effective.problems.isEmpty)
            #expect(effective.policy.allowedSignals == harness.offeredSignals.subtracting(selection))
            #expect(!effective.policy.allowedSignals.contains(.go))
        }
    }

    @Test
    func noOfferedSignalsCanStillEmitAnExplicitEmptyRepoOverride() throws {
        var harness = HarnessSettings()
        harness.offeredSignals = []
        let policy = resolve(harness)
        #expect(policy.signalOverride.choices.isEmpty)
        let fragment = try policy.signalsFragment(disabling: [])
        #expect(try disabledTokens(in: fragment).isEmpty)
        let effective = resolve(harness, try merging(fragment, into: validConfig()))
        #expect(effective.problems.isEmpty)
        #expect(effective.policy.allowedSignals.isEmpty)
        #expect(effective.settings.first { $0.name == "Signals" }?.source == .repo)
    }

    @Test
    func anyExplicitValidDisableArrayIsRepoSourcedEvenWhenItDoesNotChangeTheHarnessSet() {
        var harness = harnessSettings()
        harness.offeredSignals = [.preview, .build]
        for disabled: [String] in [[], ["go"], ["harness:go"]] {
            var repo = validConfig()
            repo.signals = .init(disable: disabled)
            let effective = resolve(harness, repo)
            #expect(effective.problems.isEmpty)
            #expect(effective.policy.allowedSignals == harness.offeredSignals)
            #expect(effective.settings.first { $0.name == "Signals" }?.source == .repo)
        }
    }

    @Test
    func missingAndNullSignalSelectionsRemainInherited() throws {
        let harness = harnessSettings()
        for json in [
            #"{"test":{"command":"swift test"}}"#,
            #"{"test":{"command":"swift test"},"signals":null}"#,
        ] {
            let repo = try RepoConfig.parse(json).config
            let effective = resolve(harness, repo)
            #expect(effective.problems.isEmpty)
            #expect(effective.policy.allowedSignals == harness.offeredSignals)
            #expect(effective.settings.first { $0.name == "Signals" }?.source == .harness)
        }
    }

    @MainActor
    @Test(arguments: AgentModels.roles)
    func policyPaneModelSelectionsDisplayAndCopyTheExactCurrentRoleFragment(
        role: AgentOSCore.AgentRole
    ) throws {
        let harness = harnessSettings()
        let policy = resolve(harness)
        let editor = PolicyOverrideEditor(policy: policy)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(editor.fragment == nil)

        for identifier in [try #require(harness.models[role]), "vendor/alternative-2026.11"] {
            try editor.selectModel(identifier, for: role)
            let displayed = try #require(editor.fragment)
            try expectModelFragment(displayed, role: role, identifier: identifier)
            pasteboard.clearContents()
            #expect(pasteboard.setString("stale clipboard contents", forType: .string))
            try editor.copy(to: pasteboard)
            let copied = try #require(pasteboard.string(forType: .string))
            #expect(copied == displayed)
            let effective = resolve(harness, try merging(copied, into: validConfig()))
            #expect(effective.problems.isEmpty)
            #expect(effective.agentModels[role] == identifier)
            #expect(try modelSetting(effective, role).source == .repo)
        }
    }

    @MainActor
    @Test
    func policyPaneMultipleSignalSelectionsCopyTheCompleteArrayAndRefreshThePreview() throws {
        var harness = harnessSettings()
        harness.offeredSignals = [.preview, .build, .retry, .go]
        var repo = validConfig()
        repo.signals = .init(disable: ["harness:go", "replan"])
        let editor = PolicyOverrideEditor(policy: resolve(harness, repo))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        for selected: Set<HarnessCommand> in [[.build, .retry], [.preview]] {
            try editor.selectSignalsToDisable(selected)
            let displayed = try #require(editor.fragment)
            #expect(Set(try disabledTokens(in: displayed)) == Set(["harness:go", "replan"] + selected.map(\.rawValue)))
            pasteboard.clearContents()
            #expect(pasteboard.setString("stale clipboard contents", forType: .string))
            try editor.copy(to: pasteboard)
            let copied = try #require(pasteboard.string(forType: .string))
            #expect(copied == displayed)
            let effective = resolve(harness, try merging(copied, into: repo))
            #expect(effective.problems.isEmpty)
            #expect(effective.policy.allowedSignals == harness.offeredSignals.subtracting(selected.union([.go])))
        }
    }

    @MainActor
    @Test
    func policyPaneSelectionsCannotBypassHarnessModelOrSignalEligibility() throws {
        var harness = harnessSettings()
        harness.offeredSignals = [.preview]
        let editor = PolicyOverrideEditor(policy: resolve(harness))
        #expect(throws: (any Error).self) {
            try editor.selectModel("vendor/not-offered", for: .implementer)
        }
        #expect(throws: (any Error).self) {
            try editor.selectSignalsToDisable([.go])
        }
        #expect(editor.fragment == nil)
    }

    private func harnessSettings() -> HarnessSettings {
        var harness = HarnessSettings()
        harness.models = AgentModels(
            decomposer: "vendor/breakdown-2026.11",
            testAuthor: "vendor/acceptance-2026.11",
            implementer: "vendor/implementation-2026.11"
        )
        harness.offeredModels = ["vendor/alternative-2026.11", "vendor/alternative-2026.11"]
        return harness
    }

    private func validConfig() -> RepoConfig {
        RepoConfig(test: .init(command: "swift test"))
    }

    private func resolve(_ harness: HarnessSettings, _ repo: RepoConfig? = nil) -> EffectivePolicy {
        EffectivePolicy.resolve(harness: harness, repo: repo, defaultBranch: "main")
    }

    private func modelSetting(
        _ policy: EffectivePolicy, _ role: AgentOSCore.AgentRole
    ) throws -> EffectiveSetting {
        try #require(policy.settings.first { $0.name == "\(role.job) agent" })
    }

    private func object(_ json: String) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(parsed as? [String: Any])
    }

    private func expectModelFragment(
        _ fragment: String, role: AgentOSCore.AgentRole, identifier: String
    ) throws {
        let root = try object(fragment)
        #expect(Set(root.keys) == ["agents"])
        let agents = try #require(root["agents"] as? [String: Any])
        #expect(Set(agents.keys) == ["models"])
        let models = try #require(agents["models"] as? [String: String])
        #expect(models == [role.rawValue: identifier])
    }

    private func disabledTokens(in fragment: String) throws -> [String] {
        let root = try object(fragment)
        #expect(Set(root.keys) == ["signals"])
        let signals = try #require(root["signals"] as? [String: Any])
        #expect(Set(signals.keys) == ["disable"])
        return try #require(signals["disable"] as? [String])
    }

    private func merging(_ fragment: String, into config: RepoConfig) throws -> RepoConfig {
        let merged = mergeObjects(try object(config.json), try object(fragment))
        let data = try JSONSerialization.data(withJSONObject: merged)
        let parsed = try RepoConfig.parse(String(decoding: data, as: UTF8.self))
        #expect(parsed.unknownKeys.isEmpty)
        return parsed.config
    }

    private func mergeObjects(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var merged = base
        for (key, value) in override {
            if let nested = value as? [String: Any], let original = merged[key] as? [String: Any] {
                merged[key] = mergeObjects(original, nested)
            } else {
                merged[key] = value
            }
        }
        return merged
    }
}
