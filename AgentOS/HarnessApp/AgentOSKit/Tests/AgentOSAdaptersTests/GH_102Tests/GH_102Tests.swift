// Expected API: persisted HarnessSettings.landingBatchSize: Int (default 4),
// RepoConfig.Limits.landingBatchSize: Int?, Policy.landingBatchSize: Int, and
// AgentOSUI.LandingBatchSizeStepper(settings: Binding<HarnessSettings>).
// Existing EffectivePolicy.resolve, .settings, .policy and .problems expose resolution.
// Reviewer-only: SettingsView embeds this editable control and saves through SettingsModel
// (criterion 1); docs/real-repo-mode.md updates both reference tables (criterion 6).
import AgentOSCore
import AgentOSTestSupport
import AgentOSUI
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentOSAdapters

@Suite struct GH_102Tests {
    @Test
    func newHarnessSettingsDefaultToFourNodesPerLandingBatch() {
        #expect(HarnessSettings().landingBatchSize == 4)
    }

    @Test(arguments: [
        "{}",
        #"{"maxParallelAgents":3,"maxAttempts":2,"avoidOverlappingWork":false}"#,
    ])
    func olderSavedSettingsWithoutABatchSizeLoadWithFour(json: String) throws {
        let settings = try JSONDecoder().decode(HarnessSettings.self, from: Data(json.utf8))
        #expect(settings.landingBatchSize == 4)
        if json != "{}" {
            #expect(settings.maxParallelAgents == 3)
            #expect(settings.maxAttempts == 2)
            #expect(!settings.avoidOverlappingWork)
        }
    }

    @Test(arguments: [1, 3, 7])
    func aChangedHarnessBatchSizeSurvivesSavingAndLoading(size: Int) throws {
        var settings = HarnessSettings()
        settings.landingBatchSize = size
        let saved = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(object["landingBatchSize"] as? Int == size)
        let restored = try JSONDecoder().decode(HarnessSettings.self, from: saved)
        #expect(restored.landingBatchSize == size)
    }

    @MainActor @Test
    func theSettingsControlShowsLandingBatchSizeAndEditsTheSavedHarnessValue() throws {
        let state = SettingsState()
        let binding = Binding(get: { state.settings }, set: { state.settings = $0 })
        let host = Self.host(LandingBatchSizeStepper(settings: binding))
        let text = try Self.text(of: host)
        #expect(RenderedUI.shows("Landing batch size", in: text), "Missing settings label:\n\(text)")
        #expect(state.settings.landingBatchSize == 4)

        try Self.step(host, by: 1)
        #expect(state.settings.landingBatchSize == 5, "Edit the bound harness settings, not private view state.")
        let saved = try JSONEncoder().encode(state.settings)
        let restored = try JSONDecoder().decode(HarnessSettings.self, from: saved)
        #expect(restored.landingBatchSize == 5)
        try Self.step(host, by: -1)
        #expect(state.settings.landingBatchSize == 4)
    }

    @Test(arguments: [1, 2, 4, 7])
    func theRepoBatchSizeIsLoadedAndPreservedAsAnInteger(size: Int) throws {
        let parsed = try RepoConfig.parse(Self.configJSON(size))
        #expect(parsed.unknownKeys.isEmpty)
        #expect(parsed.config.limits?.landingBatchSize == size)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(parsed.config.json.utf8)) as? [String: Any]
        )
        let limits = try #require(object["limits"] as? [String: Any])
        #expect(limits["landingBatchSize"] as? Int == size)
        #expect(try RepoConfig.parse(parsed.config.json).config.limits?.landingBatchSize == size)
    }

    @Test(arguments: [#""2""#, "1.5", "true", "{}", "[]"])
    func aRepoBatchSizeMustBeAnInteger(value: String) {
        #expect(throws: RepoConfig.ParseError.self) {
            try RepoConfig.parse(
                #"{"test":{"command":"swift test"},"limits":{"landingBatchSize":\#(value)}}"#
            )
        }
    }

    @Test(arguments: [1, 4, 7])
    func anOmittedRepoBatchSizeUsesTheCurrentHarnessValueAndSource(size: Int) throws {
        for config in [
            nil,
            try RepoConfig.parse(#"{"test":{"command":"swift test"}}"#).config,
            try RepoConfig.parse(#"{"test":{"command":"swift test"},"limits":{"maxAttempts":1}}"#).config,
        ] {
            let effective = Self.resolve(harnessSize: size, repo: config)
            let row = try Self.batchSetting(in: effective)
            #expect(row.value == String(size))
            #expect(row.source == .harness)
            #expect(effective.problems.isEmpty)
        }
    }

    @Test(arguments: [1, 2, 4, 7])
    func aRepoSizeFromOneThroughTheHarnessLimitIsEffectiveAndRepoSourced(size: Int) throws {
        let repo = try RepoConfig.parse(Self.configJSON(size)).config
        let effective = Self.resolve(harnessSize: 7, repo: repo)
        let row = try Self.batchSetting(in: effective)
        #expect(row.value == String(size))
        #expect(row.source == .repo, "An explicit value equal to the harness limit is still repo sourced.")
        #expect(effective.policy.landingBatchSize == size)
        #expect(effective.problems.isEmpty)
    }

    @Test
    func aRepoSizeAboveTheHarnessLimitIsBlockedWithBothValuesAndFallsBackToTheHarness() throws {
        let repo = try RepoConfig.parse(Self.configJSON(8)).config
        let effective = Self.resolve(harnessSize: 3, repo: repo)
        let blocker = try Self.batchBlocker(in: effective.problems)
        let row = try Self.batchSetting(in: effective)
        #expect(row.value == "3")
        #expect(row.source == .harness)
        #expect(effective.policy.landingBatchSize == 3)
        let explanation = (blocker.title + " " + blocker.detail).lowercased()
        #expect(explanation.contains("harness"))
        #expect(explanation.contains("repo"))
        #expect(explanation.contains("3"), "Name the harness limit.")
        #expect(explanation.contains("8"), "Name the refused repo value.")
        #expect(blocker.suggestion?.contains(RepoConfig.path) == true)
        try Self.expectReadinessBlocker(repoSize: 8, harnessSize: 3, matching: blocker)
    }

    @Test(arguments: [0, -2])
    func aRepoSizeBelowOneIsInvalidAndDoesNotReplaceTheHarnessValue(size: Int) throws {
        let repo = try RepoConfig.parse(Self.configJSON(size)).config
        let effective = Self.resolve(harnessSize: 4, repo: repo)
        let blocker = try Self.batchBlocker(in: effective.problems)
        let row = try Self.batchSetting(in: effective)
        #expect(row.value == "4")
        #expect(row.source == .harness)
        #expect(effective.policy.landingBatchSize == 4)
        let explanation = (blocker.title + " " + blocker.detail).lowercased()
        #expect(explanation.contains(String(size)))
        #expect(explanation.contains("1") || explanation.contains("positive") || explanation.contains("invalid"),
                "Explain why this repo value is invalid.")
        try Self.expectReadinessBlocker(repoSize: size, harnessSize: 4, matching: blocker)
    }

    @Test(arguments: [
        (4, Optional<Int>.none, 4),
        (7, Optional<Int>.none, 7),
        (7, Optional(1), 1),
        (7, Optional(3), 3),
        (7, Optional(7), 7),
        (3, Optional(8), 3),
        (4, Optional(0), 4),
        (4, Optional(-2), 4),
    ])
    func thePolicyForTheReconcilerCarriesTheResolvedLandingBatchSize(
        scenario: (Int, Int?, Int)
    ) throws {
        let repo = try scenario.1.map { try RepoConfig.parse(Self.configJSON($0)).config }
        let effective = Self.resolve(harnessSize: scenario.0, repo: repo)
        #expect(effective.policy.landingBatchSize == scenario.2)
    }

    @MainActor @Test(arguments: [
        (7, Optional<Int>.none, 7, "harness"),
        (7, Optional(2), 2, "repo"),
        (7, Optional(7), 7, "repo"),
        (3, Optional(8), 3, "harness"),
        (4, Optional(0), 4, "harness"),
    ])
    func thePolicyPaneShowsTheLandingBatchSizeWithItsEffectiveValueAndSource(
        scenario: (Int, Int?, Int, String)
    ) throws {
        let repo = try scenario.1.map { try RepoConfig.parse(Self.configJSON($0)).config }
        var effective = Self.resolve(harnessSize: scenario.0, repo: repo)
        effective.settings = [try Self.batchSetting(in: effective)]
        let model = HarnessViewModel()
        model.policy = effective
        let text = try Self.text(of: Self.host(PolicyPane().environment(model), height: 600))
        #expect(RenderedUI.shows("Landing batch size", in: text), "Missing policy label:\n\(text)")
        #expect(Self.hasStandalone(String(scenario.2), in: text), "Missing effective batch size:\n\(text)")
        #expect(Self.hasSource(scenario.3, label: "Landing batch size", in: text), "Missing row source:\n\(text)")
    }

    @MainActor @Test
    func theUIHelpersCanEditAnExistingStepperAndReadAnExistingSourcedPolicyRow() throws {
        let state = SettingsState()
        let control = Self.host(Stepper(
            "Existing limit: \(state.probeLimit)",
            value: Binding(get: { state.probeLimit }, set: { state.probeLimit = $0 }),
            in: 1...8
        ))
        #expect(RenderedUI.shows("Existing limit", in: try Self.text(of: control)))
        try Self.step(control, by: 1)
        #expect(state.probeLimit == 5)
        try Self.step(control, by: -1)
        #expect(state.probeLimit == 4)

        var effective = EffectivePolicy.resolve(harness: HarnessSettings(), repo: nil, defaultBranch: "main")
        effective.settings = effective.settings.filter { $0.name == "Max parallel agents" }
        try #require(effective.settings.count == 1)
        let model = HarnessViewModel()
        model.policy = effective
        let text = try Self.text(of: Self.host(PolicyPane().environment(model), height: 600))
        #expect(RenderedUI.shows("Max parallel agents", in: text))
        #expect(Self.hasStandalone("2", in: text))
        #expect(Self.hasStandalone("3", in: "\u{0417}"))
        #expect(!Self.hasStandalone("3", in: "8"))
        #expect(!Self.hasStandalone("3", in: "repo asked for 3: refused"))
        #expect(Self.hasSource("harness", label: "Max parallel agents", in: text))
        #expect(!Self.hasSource("repo", label: "Max parallel agents", in: text),
                "The header's mention of repo must not be mistaken for the row source.")
    }
}
