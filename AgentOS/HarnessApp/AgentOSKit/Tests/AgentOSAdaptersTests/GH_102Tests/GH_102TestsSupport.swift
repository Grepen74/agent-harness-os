import AgentOSCore
import AgentOSTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentOSAdapters

extension GH_102Tests {
    static func configJSON(_ size: Int) -> String {
        #"{"test":{"command":"swift test"},"limits":{"landingBatchSize":\#(size)}}"#
    }

    static func resolve(harnessSize: Int, repo: RepoConfig? = nil) -> EffectivePolicy {
        var harness = HarnessSettings()
        harness.landingBatchSize = harnessSize
        return EffectivePolicy.resolve(harness: harness, repo: repo, defaultBranch: "main")
    }

    static func batchSetting(in effective: EffectivePolicy) throws -> EffectiveSetting {
        let rows = effective.settings.filter { $0.name == "Landing batch size" }
        #expect(rows.count == 1, "Expose one unambiguous Landing batch size setting.")
        return try #require(rows.first)
    }

    static func batchBlocker(in findings: [Finding]) throws -> Finding {
        try #require(findings.first {
            let text = ($0.title + " " + $0.detail).lowercased()
            return $0.check == "config.policy" && $0.severity == .blocker
                && (text.contains("landing batch size") || text.contains("landingbatchsize"))
        }, "Refuse an invalid landing batch size with a setting-specific config.policy blocker.")
    }

    static func expectReadinessBlocker(
        repoSize: Int, harnessSize: Int, matching blocker: Finding
    ) throws {
        var harness = HarnessSettings()
        harness.landingBatchSize = harnessSize
        let snapshot = RepositorySnapshot(
            branch: "main", commit: "gh102-base", files: [RepoConfig.path],
            contents: [RepoConfig.path: Self.configJSON(repoSize)]
        )
        let assessment = ReadinessRules.assess(snapshot, harness: harness, baseline: nil)
        #expect(assessment.findings.contains(blocker), "The refusal must appear in the repo readiness scan.")
        let scan = ReadinessScan(branch: "main", commit: "gh102-base", findings: assessment.findings)
        #expect(!scan.isReady)
        #expect(RepositorySession.blockers(scan).contains(blocker.title))
    }

    @MainActor
    static func host<Content: View>(_ view: Content, height: CGFloat = 120) -> NSView {
        _ = NSApplication.shared
        let size = CGSize(width: 1_000, height: height)
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US")))
        host.frame = CGRect(origin: .zero, size: size)
        return host
    }

    @MainActor
    static func text(of view: NSView) throws -> String {
        try RenderedUI.text(in: RenderedUI.image(of: view)).joined(separator: "\n")
    }

    @MainActor
    static func step(_ view: NSView, by direction: Int) throws {
        let control = try #require(Self.descendants(view, as: NSStepper.self).first,
                                   "The settings control must expose an editable stepper.")
        let action = try #require(control.action)
        control.integerValue += direction
        #expect(NSApplication.shared.sendAction(action, to: control.target, from: control))
    }

    @MainActor
    private static func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { Self.descendants($0, as: type) }
    }

    static func hasStandalone(_ expected: String, in text: String) -> Bool {
        text.components(separatedBy: .newlines).contains {
            let recognized = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Vision can read a displayed 3 as the visually identical Cyrillic letter Ze.
            let value = Int(expected) == nil ? recognized
                : recognized.replacingOccurrences(of: "\u{0437}", with: "3")
            return value == expected.lowercased()
        }
    }

    @MainActor
    static func hasSource(_ source: String, label: String, in text: String) -> Bool {
        Self.hasStandalone(source, in: text) || RenderedUI.shows(label + source, in: text)
    }

    @MainActor
    final class SettingsState {
        var settings = HarnessSettings()
        var probeLimit = 4
    }
}
