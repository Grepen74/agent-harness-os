import AgentOSCore
import AgentOSTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing

extension GH_76Tests {
    static var label: String { "Avoid building overlapping work at the same time" }

    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func harness(_ enabled: Bool) -> HarnessSettings {
        var settings = HarnessSettings()
        settings.avoidOverlappingWork = enabled
        return settings
    }

    static func resolve(_ enabled: Bool, repo: RepoConfig? = nil) -> EffectivePolicy {
        EffectivePolicy.resolve(harness: Self.harness(enabled), repo: repo, defaultBranch: "main")
    }

    static func setting(in policy: EffectivePolicy) throws -> EffectiveSetting {
        let rows = policy.settings.filter { $0.name == Self.label }
        #expect(rows.count == 1, "There must be one unambiguous effective overlap setting.")
        return try #require(rows.first)
    }

    static func configJSON(_ enabled: Bool) -> String {
        """
        {"test":{"command":"swift test"},"limits":{"avoidOverlappingWork":\(enabled)}}
        """
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func hasStandalone(_ expected: String, in text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { Self.normalized($0) == Self.normalized(expected) }
    }

    @MainActor
    static func hasSource(_ source: String, label: String, in text: String) -> Bool {
        Self.hasStandalone(source, in: text) || RenderedUI.shows(label + source, in: text)
    }

    @MainActor
    static func host<Content: View>(_ view: Content, height: CGFloat = 120) -> (view: NSView, window: NSWindow) {
        _ = NSApplication.shared
        let size = CGSize(width: 1_000, height: height)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "en_US")))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(!window.isVisible)
        return (hosting, window)
    }

    @MainActor
    static func text(of view: NSView) throws -> String {
        try RenderedUI.text(in: RenderedUI.image(of: view)).joined(separator: "\n")
    }

    @MainActor
    static func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { Self.descendants($0, as: type) }
    }

    @MainActor final class SettingsState {
        var value = HarnessSettings()
        var probeValue = true
    }

    struct ProbeToggleStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            Toggle(configuration).toggleStyle(.checkbox)
                .background(ToggleProbeBridge(choice: configuration.$isOn))
        }
    }

    private struct ToggleProbeBridge: NSViewRepresentable {
        let choice: Binding<Bool>

        func makeNSView(context: Context) -> ToggleProbe { ToggleProbe() }

        func updateNSView(_ view: ToggleProbe, context: Context) {
            view.choice = choice
        }
    }

    @MainActor final class ToggleProbe: NSView {
        var choice: Binding<Bool>?
    }
}
