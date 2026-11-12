// API contract: EffectiveSetting.overrides supplies [RepoConfigOverride] (value: String, json: String),
// and overrideActionTitle is nil or "Override in repo config…". EffectivePolicy.resolve supplies these
// from the same constraints it validates. AgentOSUI.PolicyOverrideControl.init(setting:pasteboard:)
// constructs an NSView with an NSPopUpButton offering those choices; choosing one shows a read-only,
// selectable NSTextView and an NSButton("Copy"). The pane uses this control for these four settings.

import AgentOSCore
import AgentOSUI
import AppKit
import CoreFoundation
import Foundation
import SwiftUI
import Testing

@Suite
struct GH_54Tests {
    private enum Setting: String, CaseIterable {
        case guesswork, maxAttempts, maxReworks, maxParallelAgents

        var name: String {
            switch self {
            case .guesswork: "Guesswork"
            case .maxAttempts: "Max attempts per leaf"
            case .maxReworks: "Max reworks per leaf"
            case .maxParallelAgents: "Max parallel agents"
            }
        }

        var section: String { self == .guesswork ? "agents" : "limits" }

        func effectiveValue(_ policy: EffectivePolicy) -> String {
            switch self {
            case .guesswork: policy.policy.guesswork.rawValue
            case .maxAttempts: String(policy.policy.maxAttempts)
            case .maxReworks: String(policy.policy.maxReworks)
            case .maxParallelAgents: String(policy.policy.maxParallelAgents)
            }
        }
    }

    @Test
    func rowsShowFriendlyGuessworkAndExactConfigValues() throws {
        for level in Guesswork.allCases {
            let policy = resolve(harness(guesswork: level))
            let row = try row(.guesswork, in: policy)
            #expect(row.value == "\(level.title) (`\(level.rawValue)`)")
        }
        let policy = resolve(harness(attempts: 7, reworks: 4, parallel: 2))
        #expect(try row(.maxAttempts, in: policy).value == "7")
        #expect(try row(.maxReworks, in: policy).value == "4")
        #expect(try row(.maxParallelAgents, in: policy).value == "2")
    }

    @Test
    func allFourRowsOfferTheOverrideActionAndNoOtherSettingsAreRequired() throws {
        let policy = resolve(harness())
        for setting in Setting.allCases {
            let row = try row(setting, in: policy)
            #expect(row.overrideActionTitle == "Override in repo config…")
            #expect(!row.overrides.isEmpty)
        }
    }

    @Test
    func everyGuessworkCeilingOffersPreciselyTheEnumValuesItAccepts() throws {
        let expected: [(Guesswork, [String])] = [
            (.ask, ["ask"]),
            (.assumeAndReport, ["ask", "assume-and-report"]),
            (.autonomous, ["ask", "assume-and-report", "autonomous"]),
        ]
        for (ceiling, tokens) in expected {
            let settings = harness(guesswork: ceiling)
            let offered = try row(.guesswork, in: resolve(settings)).overrides
            #expect(Set(offered.map(\.value)) == Set(tokens))
            #expect(offered.count == tokens.count)
            for candidate in Guesswork.allCases {
                let policy = try resolve(settings, setting: .guesswork, value: candidate.rawValue)
                let accepted = tokens.contains(candidate.rawValue)
                #expect(policy.problems.isEmpty == accepted)
                #expect(offered.contains { $0.value == candidate.rawValue } == accepted)
                #expect(try row(.guesswork, in: policy).source == (accepted ? .repo : .harness))
                #expect(policy.policy.guesswork == (accepted ? candidate : ceiling))
                if !accepted {
                    #expect(policy.problems.contains { $0.severity == .blocker })
                    #expect(try row(.guesswork, in: policy).note != nil)
                }
            }
        }
    }

    @Test
    func eachLimitOffersEveryIntegerFromOneThroughItsOwnHarnessMaximum() throws {
        for maximum in [1, 2, 5] {
            for setting in Setting.allCases where setting != .guesswork {
                var settings = harness(attempts: 7, reworks: 4, parallel: 3)
                setMaximum(maximum, for: setting, in: &settings)
                let offered = try row(setting, in: resolve(settings)).overrides
                let expected = (1...maximum).map(String.init)
                #expect(Set(offered.map(\.value)) == Set(expected))
                #expect(offered.count == maximum)

                // Include every interior value and both invalid neighbours, not just the defaults.
                for candidate in -1...(maximum + 1) {
                    let policy = try resolve(settings, setting: setting, value: String(candidate))
                    let accepted = (1...maximum).contains(candidate)
                    #expect(policy.problems.isEmpty == accepted)
                    #expect(offered.contains { $0.value == String(candidate) } == accepted)
                    #expect(setting.effectiveValue(policy) == String(accepted ? candidate : maximum))
                    #expect(try row(setting, in: policy).source == (accepted ? .repo : .harness))
                    if !accepted {
                        #expect(policy.problems.contains { $0.severity == .blocker })
                        #expect(try row(setting, in: policy).note != nil)
                    }
                }
            }
        }
    }

    @Test
    func choicesUseTheHarnessCeilingNotAnAlreadyTightenedRepoValue() throws {
        let settings = harness(guesswork: .autonomous, attempts: 5, reworks: 4, parallel: 3)
        let repo = RepoConfig(test: .init(command: "swift test"),
                              limits: .init(maxAttempts: 1, maxReworks: 1, maxParallelAgents: 1),
                              agents: .init(guesswork: "ask"))
        let inherited = resolve(settings)
        let tightened = resolve(settings, repo: repo)
        #expect(tightened.problems.isEmpty)
        for setting in Setting.allCases {
            #expect(try row(setting, in: tightened).source == .repo)
            #expect(try row(setting, in: tightened).overrides == row(setting, in: inherited).overrides)
        }
    }

    @Test
    func everyOfferedFragmentHasOnlyTheFullConfigPathAndRoundTripsIntoAValidConfig() throws {
        for ceiling in Guesswork.allCases {
            let settings = harness(guesswork: ceiling, attempts: 4, reworks: 3, parallel: 2)
            let original = resolve(settings)
            for setting in Setting.allCases {
                for choice in try row(setting, in: original).overrides {
                    let fragment = try object(choice.json)
                    #expect(Set(fragment.keys) == [setting.section])
                    let nested = try #require(fragment[setting.section] as? [String: Any])
                    #expect(Set(nested.keys) == [setting.rawValue])
                    if setting == .guesswork {
                        #expect(nested[setting.rawValue] as? String == choice.value)
                    } else {
                        let number = try #require(nested[setting.rawValue] as? NSNumber)
                        #expect(CFGetTypeID(number) != CFBooleanGetTypeID())
                        #expect(number.stringValue == choice.value)
                        #expect(Int(choice.value) != nil)
                    }

                    // Merge into existing sections so a fragment cannot accidentally erase other config.
                    var complete = try object(baseConfig.json)
                    for (key, value) in fragment {
                        var section = complete[key] as? [String: Any] ?? [:]
                        section.merge(try #require(value as? [String: Any])) { _, selected in selected }
                        complete[key] = section
                    }
                    let parsed = try RepoConfig.parse(json(complete))
                    #expect(parsed.unknownKeys.isEmpty)
                    #expect(parsed.config.test == baseConfig.test)
                    #expect(parsed.config.build == baseConfig.build)
                    #expect(parsed.config.agents?.context == baseConfig.agents?.context)
                    #expect(parsed.config.agents?.deny == baseConfig.agents?.deny)
                    let policy = resolve(settings, repo: parsed.config)
                    #expect(policy.problems.isEmpty)
                    #expect(setting.effectiveValue(policy) == choice.value)
                    #expect(try row(setting, in: policy).source == .repo)
                    #expect(try row(setting, in: policy).note == nil)
                    for other in Setting.allCases where other != setting {
                        #expect(other.effectiveValue(policy) == other.effectiveValue(original))
                        #expect(try row(other, in: policy).source == .harness)
                    }
                }
            }
        }
    }

    @Test
    func absentEqualAndRefusedRepoValuesHaveTheRequiredSource() throws {
        let settings = harness()
        for repo in [nil, RepoConfig(test: .init(command: "swift test"))] {
            let policy = resolve(settings, repo: repo)
            for setting in Setting.allCases {
                #expect(try row(setting, in: policy).source == .harness)
            }
        }
        for setting in Setting.allCases {
            let inherited = resolve(settings)
            let same = setting.effectiveValue(inherited)
            let explicit = try resolve(settings, setting: setting, value: same)
            #expect(explicit.problems.isEmpty)
            #expect(try row(setting, in: explicit).source == .repo)
            #expect(setting.effectiveValue(explicit) == same)
            let refused = try resolve(settings, setting: setting,
                                      value: setting == .guesswork ? "not-a-level" : "0")
            #expect(!refused.problems.isEmpty)
            #expect(try row(setting, in: refused).source == .harness)
            #expect(setting.effectiveValue(refused) == same)
        }
    }

    @MainActor @Test
    func selectingEachChoiceShowsSelectableJsonAndCopyReplacesTheClipboardWithoutEditingConfig() throws {
        _ = NSApplication.shared
        let settings = harness(guesswork: .autonomous, attempts: 3, reworks: 2, parallel: 2)
        let config = baseConfig
        let policy = resolve(settings, repo: config)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for setting in Setting.allCases {
            let row = try row(setting, in: policy)
            let control = PolicyOverrideControl(setting: row, pasteboard: pasteboard)
            control.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
            control.layoutSubtreeIfNeeded()
            let popup = try #require(descendants(of: control, as: NSPopUpButton.self).first)
            #expect(popup.title == "Override in repo config…")
            #expect(popup.itemTitles.filter { $0 != "Override in repo config…" }.sorted()
                    == row.overrides.map(\.value).sorted())
            for choice in row.overrides {
                pasteboard.clearContents()
                #expect(pasteboard.setString("old clipboard contents", forType: .string))
                try select(choice.value, in: popup)
                control.layoutSubtreeIfNeeded()
                #expect(pasteboard.string(forType: .string) == "old clipboard contents")
                let text = try #require(descendants(of: control, as: NSTextView.self).first {
                    $0.string == choice.json
                })
                #expect(text.isSelectable)
                #expect(!text.isEditable)
                let range = NSRange(location: 0, length: (text.string as NSString).length)
                text.setSelectedRange(range)
                #expect(text.selectedRange() == range)
                let copy = try #require(descendants(of: control, as: NSButton.self).first { $0.title == "Copy" })
                #expect(copy.isEnabled)
                copy.performClick(nil)
                #expect(pasteboard.string(forType: .string) == choice.json)
            }
        }
    }

    @MainActor @Test
    func selectingAndCopyingWithNoConfigDoesNotCreateOne() throws {
        _ = NSApplication.shared
        let model = HarnessViewModel()
        let actions = ConfigWriteSpy()
        model.actions = actions
        model.policy = resolve(harness())
        #expect(model.config == nil)
        let host = NSHostingView(rootView: PolicyPane().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 2400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        // Inspect real AppKit descendants, never the hosting view's empty accessibility tree.
        let controls = descendants(of: host, as: PolicyOverrideControl.self)
        #expect(controls.count == Setting.allCases.count)
        let savedClipboard = NSPasteboard.general.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        } ?? []
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedClipboard)
        }
        let policy = try #require(model.policy)
        for control in controls {
            let popup = try #require(descendants(of: control, as: NSPopUpButton.self).first)
            let value = try #require(popup.itemTitles.last { $0 != "Override in repo config…" })
            try select(value, in: popup)
            control.layoutSubtreeIfNeeded()
            let text = try #require(descendants(of: control, as: NSTextView.self).first)
            #expect(policy.settings.flatMap(\.overrides).contains { $0.json == text.string })
            let copy = try #require(descendants(of: control, as: NSButton.self).first { $0.title == "Copy" })
            copy.performClick(nil)
            #expect(NSPasteboard.general.string(forType: .string) == text.string)
            #expect(model.config == nil)
            #expect(actions.openConfigCalls == 0)
            #expect(actions.openedPaths.isEmpty)
        }
    }

    private var baseConfig: RepoConfig {
        RepoConfig(build: .init(command: "swift build"), test: .init(command: "swift test", only: "--filter {suite}"),
                   agents: .init(deny: ["extra-tool"], context: ["README.md"]))
    }

    private func harness(guesswork: Guesswork = .assumeAndReport, attempts: Int = 3,
                         reworks: Int = 3, parallel: Int = 2) -> HarnessSettings {
        var settings = HarnessSettings()
        settings.guesswork = guesswork
        settings.maxAttempts = attempts
        settings.maxReworks = reworks
        settings.maxParallelAgents = parallel
        return settings
    }

    private func setMaximum(_ value: Int, for setting: Setting, in harness: inout HarnessSettings) {
        switch setting {
        case .guesswork: preconditionFailure("Not an integer setting")
        case .maxAttempts: harness.maxAttempts = value
        case .maxReworks: harness.maxReworks = value
        case .maxParallelAgents: harness.maxParallelAgents = value
        }
    }

    private func resolve(_ harness: HarnessSettings, repo: RepoConfig? = nil) -> EffectivePolicy {
        EffectivePolicy.resolve(harness: harness, repo: repo, defaultBranch: "main")
    }

    private func resolve(_ harness: HarnessSettings, setting: Setting, value: String) throws -> EffectivePolicy {
        let selected: Any
        if setting == .guesswork {
            selected = value
        } else {
            selected = try #require(Int(value))
        }
        let parsed = try RepoConfig.parse(json([
            "test": ["command": "swift test"],
            setting.section: [setting.rawValue: selected],
        ]))
        #expect(parsed.unknownKeys.isEmpty)
        return resolve(harness, repo: parsed.config)
    }

    private func row(_ setting: Setting, in policy: EffectivePolicy) throws -> EffectiveSetting {
        try #require(policy.settings.first { $0.name == setting.name })
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @MainActor
    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var matches: [T] = []
        for child in view.subviews {
            if let match = child as? T { matches.append(match) }
            matches += descendants(of: child, as: type)
        }
        return matches
    }

    @MainActor
    private func select(_ value: String, in popup: NSPopUpButton) throws {
        let item = try #require(popup.item(withTitle: value))
        #expect(item.isEnabled)
        popup.select(item)
        let action = try #require(popup.action)
        #expect(popup.sendAction(action, to: popup.target))
    }

    @MainActor
    private final class ConfigWriteSpy: HarnessActions {
        var openConfigCalls = 0
        var openedPaths: [String] = []
        func openRepoConfig() { openConfigCalls += 1 }
        func open(_ path: String) { openedPaths.append(path) }
        func stopRun(node: NodeID, run: RunID, by person: String) async {}
        func addLabel(_ name: String, to key: String) async {}
        func removeLabel(_ name: String, from key: String) async {}
        func comment(_ text: String, on key: String) async {}
        func createTicket(title: String, description: String, criteria: [String], blockedBy: [String]) async {}
        func edit(_ key: String, title: String, description: String, criteria: [String], blockedBy: [String]) async {}
        func verifyChain() async {}
    }
}
