// API contract: HarnessSettings.avoidOverlappingWork is a persisted Bool, defaulting to true;
// RepoConfig.Limits.avoidOverlappingWork is an optional Bool. EffectivePolicy.resolve exposes the
// effective value as Policy.avoidOverlappingWork and a sourced EffectiveSetting. The app's Settings
// window uses AgentOSUI.AvoidOverlappingWorkToggle(settings: Binding<HarnessSettings>).
import AgentOSCore
import AgentOSTestSupport
import AgentOSUI
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentOSAdapters

@Suite struct GH_76Tests {
    @Test
    func newAndPreviouslySavedHarnessSettingsAvoidOverlappingWorkByDefault() throws {
        #expect(HarnessSettings().avoidOverlappingWork)
        let legacy = Data("""
            {"landingBranch":"agentos/proven","maxParallelAgents":4,"maxAttempts":2}
            """.utf8)
        let restored = try JSONDecoder().decode(HarnessSettings.self, from: legacy)
        #expect(restored.avoidOverlappingWork)
        #expect(restored.landingBranch == "agentos/proven")
        #expect(restored.maxParallelAgents == 4)
        #expect(restored.maxAttempts == 2)
        #expect(try JSONDecoder().decode(HarnessSettings.self, from: Data("{}".utf8)).avoidOverlappingWork)
    }

    @Test(arguments: [false, true])
    func theHarnessChoiceSurvivesSavingAndReloading(enabled: Bool) throws {
        var settings = HarnessSettings()
        settings.avoidOverlappingWork = enabled
        let saved = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(object["avoidOverlappingWork"] as? Bool == enabled)
        let restored = try JSONDecoder().decode(HarnessSettings.self, from: saved)
        #expect(restored.avoidOverlappingWork == enabled)
    }

    @Test(arguments: [false, true])
    func theRepoLimitIsABooleanThatSurvivesConfigLoadingAndSaving(enabled: Bool) throws {
        let parsed = try RepoConfig.parse(Self.configJSON(enabled))
        #expect(parsed.unknownKeys.isEmpty)
        #expect(parsed.config.limits?.avoidOverlappingWork == enabled)
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(parsed.config.json.utf8)) as? [String: Any]
        )
        let limits = try #require(saved["limits"] as? [String: Any])
        #expect(limits["avoidOverlappingWork"] as? Bool == enabled)
        #expect(try RepoConfig.parse(parsed.config.json).config.limits?.avoidOverlappingWork == enabled)
    }

    @Test(arguments: [false, true])
    func anOmittedRepoSettingInheritsTheHarnessValueAndSource(enabled: Bool) throws {
        for config in [
            nil,
            try RepoConfig.parse(#"{"test":{"command":"swift test"}}"#).config,
            try RepoConfig.parse(#"{"test":{"command":"swift test"},"limits":{}}"#).config,
        ] {
            let effective = Self.resolve(enabled, repo: config)
            let row = try Self.setting(in: effective)
            #expect(row.value == (enabled ? "On" : "Off"))
            #expect(row.source == .harness)
            #expect(row.note == nil)
            #expect(effective.problems.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func anExplicitRepoTrueIsRepoSourcedEvenWhenTheHarnessAlreadyHasItOn(harnessEnabled: Bool) throws {
        let repo = try RepoConfig.parse(Self.configJSON(true)).config
        let effective = Self.resolve(harnessEnabled, repo: repo)
        let row = try Self.setting(in: effective)
        #expect(row.value == "On")
        #expect(row.source == .repo)
        #expect(row.note == nil)
        #expect(effective.problems.isEmpty)
    }

    @Test
    func aRepoCanTurnOverlapAvoidanceOnWhenTheHarnessHasItOff() throws {
        let repo = try RepoConfig.parse(Self.configJSON(true)).config
        let inherited = Self.resolve(false)
        let tightened = Self.resolve(false, repo: repo)
        #expect(try Self.setting(in: inherited).value == "Off")
        #expect(try Self.setting(in: tightened).value == "On")
        #expect(tightened.policy.avoidOverlappingWork)
        #expect(tightened.problems.isEmpty)
    }

    @Test
    func aRepoCannotTurnTheHarnessProtectionOffAndGetsAnActionablePolicyBlocker() throws {
        let repo = try RepoConfig.parse(Self.configJSON(false)).config
        let effective = Self.resolve(true, repo: repo)
        let row = try Self.setting(in: effective)
        #expect(row.value == "On")
        #expect(row.source == .harness)
        #expect(row.note == "repo asked for false: refused")
        #expect(effective.policy.avoidOverlappingWork)
        let blocker = try #require(effective.problems.first {
            $0.check == "config.policy" && $0.severity == .blocker
        })
        let explanation = (blocker.title + " " + blocker.detail).lowercased()
        #expect(explanation.contains("overlap"), "The finding must identify the setting that was refused.")
        #expect(blocker.suggestion?.contains(RepoConfig.path) == true)

        let snapshot = RepositorySnapshot(
            branch: "main", commit: "gh76-base", files: [RepoConfig.path],
            contents: [RepoConfig.path: Self.configJSON(false)]
        )
        let assessment = ReadinessRules.assess(snapshot, harness: Self.harness(true), baseline: nil)
        #expect(assessment.findings.contains(blocker), "The refusal must reach the readiness scan.")
        let scan = ReadinessScan(branch: "main", commit: "gh76-base", findings: assessment.findings)
        #expect(!scan.isReady)
        #expect(RepositorySession.blockers(scan).contains(blocker.title))
    }

    @Test
    func aFalseRepoValueDoesNotClaimRepoSourceWhenTheHarnessIsAlreadyOff() throws {
        let repo = try RepoConfig.parse(Self.configJSON(false)).config
        let effective = Self.resolve(false, repo: repo)
        let row = try Self.setting(in: effective)
        #expect(row.value == "Off")
        #expect(row.source == .harness)
        #expect(!effective.policy.avoidOverlappingWork)
    }

    @Test(arguments: [
        (false, Optional<Bool>.none, false),
        (true, Optional<Bool>.none, true),
        (false, Optional(true), true),
        (true, Optional(true), true),
        (false, Optional(false), false),
        (true, Optional(false), true),
    ])
    func thePolicyPassedToTheReconcilerCarriesTheEffectiveChoice(
        scenario: (Bool, Bool?, Bool)
    ) throws {
        let repo = try scenario.1.map { try RepoConfig.parse(Self.configJSON($0)).config }
        let effective = Self.resolve(scenario.0, repo: repo)
        #expect(effective.policy.avoidOverlappingWork == scenario.2)
        #expect(try Self.setting(in: effective).value == (scenario.2 ? "On" : "Off"))
    }

    @MainActor @Test
    func theSettingsToggleHasThePromisedLabelAndEditsThePersistedHarnessChoice() throws {
        let state = SettingsState()
        let binding = Binding(get: { state.value }, set: { state.value = $0 })
        let host = Self.host(AvoidOverlappingWorkToggle(settings: binding).toggleStyle(ProbeToggleStyle()))
        defer { host.window.close() }
        let text = try Self.text(of: host.view)
        #expect(RenderedUI.shows(Self.label, in: text), "Missing settings label:\n\(text)")
        let control = try #require(Self.descendants(host.view, as: ToggleProbe.self).first,
                                   "Settings must expose a Toggle, not only explanatory text.")
        let choice = try #require(control.choice)
        #expect(choice.wrappedValue)
        choice.wrappedValue = false
        #expect(!state.value.avoidOverlappingWork)
        #expect(!Self.resolve(state.value.avoidOverlappingWork).policy.avoidOverlappingWork)
        let saved = try JSONEncoder().encode(state.value)
        #expect(try !JSONDecoder().decode(HarnessSettings.self, from: saved).avoidOverlappingWork)
        choice.wrappedValue = true
        #expect(state.value.avoidOverlappingWork)
    }

    @MainActor @Test(arguments: [
        (false, Optional<Bool>.none, "Off", "harness"),
        (true, Optional<Bool>.none, "On", "harness"),
        (false, Optional(true), "On", "repo"),
        (true, Optional(false), "On", "harness"),
    ])
    func thePolicyPaneShowsTheOverlapSettingValueAndItsSource(
        scenario: (Bool, Bool?, String, String)
    ) throws {
        let repo = try scenario.1.map { try RepoConfig.parse(Self.configJSON($0)).config }
        var policy = Self.resolve(scenario.0, repo: repo)
        let row = try Self.setting(in: policy)
        policy.settings = [row]
        let model = HarnessViewModel()
        model.policy = policy
        let host = Self.host(PolicyPane().environment(model), height: 600)
        defer { host.window.close() }
        let text = try Self.text(of: host.view)
        #expect(RenderedUI.shows(Self.label, in: text), "Missing policy row:\n\(text)")
        #expect(Self.hasStandalone(scenario.2, in: text), "Missing effective value:\n\(text)")
        #expect(Self.hasSource(scenario.3, label: Self.label, in: text), "Missing row source:\n\(text)")
        if scenario.1 == false && scenario.0 {
            #expect(RenderedUI.shows("repo asked for false: refused", in: text))
        }
    }

    @MainActor @Test
    func theUIProbesReadAnExistingToggleAndAnExistingSourcedPolicyRow() throws {
        let state = SettingsState()
        let toggle = Self.host(Toggle("Existing toggle probe", isOn: Binding(
            get: { state.probeValue }, set: { state.probeValue = $0 }
        )).toggleStyle(ProbeToggleStyle()))
        defer { toggle.window.close() }
        #expect(RenderedUI.shows("Existing toggle probe", in: try Self.text(of: toggle.view)))
        let control = try #require(Self.descendants(toggle.view, as: ToggleProbe.self).first)
        let choice = try #require(control.choice)
        #expect(choice.wrappedValue)
        choice.wrappedValue = false
        #expect(!state.probeValue)
        choice.wrappedValue = true
        #expect(state.probeValue)

        var policy = Self.resolve(true)
        policy.settings = policy.settings.filter { $0.name == "Landing branch" }
        let model = HarnessViewModel()
        model.policy = policy
        let pane = Self.host(PolicyPane().environment(model), height: 600)
        defer { pane.window.close() }
        let text = try Self.text(of: pane.view)
        #expect(RenderedUI.shows("Landing branch", in: text))
        #expect(RenderedUI.shows("agentos/<ticket key>", in: text))
        #expect(Self.hasSource("harness", label: "Landing branch", in: text), "\(text)")
        #expect(!Self.hasSource("repo", label: "Landing branch", in: text),
                "The repo mentioned in the pane header must not look like the row's source.")
    }

    @Test(arguments: [
        "AgentOS/HarnessApp/docs/real-repo-mode.md",
        "AgentOS/HarnessApp/README.md",
    ])
    func userDocumentationDescribesOverlapAvoidanceAndTheOneWayRepoOverride(path: String) throws {
        let document = try String(contentsOf: Self.root.appending(path: path), encoding: .utf8)
        let passages = document.components(separatedBy: "\n\n").map(Self.normalized)
        let relevant = passages.filter {
            $0.contains(Self.label.lowercased()) || $0.contains("limits.avoidoverlappingwork")
        }
        #expect(!relevant.isEmpty, "\(path) must describe the overlap setting.")
        #expect(relevant.contains { passage in
            passage.contains("repo")
                && passage.range(of: #"(may|can|only|allow)[^.]*\b(on|enable|true)\b"#,
                                 options: .regularExpression) != nil
                && passage.range(of: #"(not|never|cannot|can't|refus)[^.]*\b(off|disable|false)\b"#,
                                 options: .regularExpression) != nil
        }, "\(path) must explain that a repo may turn the setting on but not off.")
    }
}
