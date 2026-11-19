import AgentOSCore
import AgentOSTestSupport
import AgentOSUI
import AppKit
import SwiftUI
import Testing

extension GH_90Tests {
    @MainActor @Test
    func theSettingsControlDisplaysThePublishingLabelAndEditsTheSavedChoice() throws {
        let settings = PublishingSettingsState()
        let binding = Binding(get: { settings.value }, set: { settings.value = $0 })
        let host = Self.hostToggle(PushPullRequestsToggle(settings: binding))
        let text = try RenderedUI.text(in: RenderedUI.image(of: host)).joined(separator: "\n")
        #expect(RenderedUI.shows("Push / open pull requests", in: text))
        let choice = try Self.toggleBinding(in: host)
        #expect(!choice.wrappedValue)
        choice.wrappedValue = true
        #expect(settings.value.pullRequests, "The control must edit the harness model, not private view state.")
        let saved = try JSONEncoder().encode(settings.value)
        #expect(try JSONDecoder().decode(HarnessSettings.self, from: saved).pullRequests)
        choice.wrappedValue = false
        #expect(!settings.value.pullRequests)
    }

    @MainActor @Test
    func theToggleProbeAndSharedRendererWorkWithAnExistingSettingsControl() throws {
        let settings = PublishingSettingsState()
        let binding = Binding(get: { settings.value }, set: { settings.value = $0 })
        let host = Self.hostToggle(AvoidOverlappingWorkToggle(settings: binding))
        let text = try RenderedUI.text(in: RenderedUI.image(of: host)).joined(separator: "\n")
        try #require(RenderedUI.shows("Avoid building overlapping work at the same time", in: text))
        let choice = try Self.toggleBinding(in: host)
        try #require(choice.wrappedValue)
        choice.wrappedValue = false
        #expect(!settings.value.avoidOverlappingWork)
        choice.wrappedValue = true
        #expect(settings.value.avoidOverlappingWork)
    }

    @MainActor
    private static func hostToggle<Content: View>(_ view: Content) -> NSView {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.toggleStyle(PublishingProbeStyle())
            .padding(20).frame(width: 1000, height: 120)
            .environment(\.colorScheme, .light))
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 120)
        return host
    }

    @MainActor
    private static func toggleBinding(in view: NSView) throws -> Binding<Bool> {
        func descendants(_ view: NSView) -> [PublishingToggleProbe] {
            ((view as? PublishingToggleProbe).map { [$0] } ?? []) + view.subviews.flatMap(descendants)
        }
        let probe = try #require(descendants(view).first, "The settings control must contain an editable Toggle.")
        return try #require(probe.choice)
    }

    @MainActor private final class PublishingSettingsState {
        var value = HarnessSettings()
    }

    private struct PublishingProbeStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            Toggle(configuration).toggleStyle(.checkbox)
                .background(PublishingProbeBridge(choice: configuration.$isOn))
        }
    }

    private struct PublishingProbeBridge: NSViewRepresentable {
        let choice: Binding<Bool>
        func makeNSView(context: Context) -> PublishingToggleProbe { PublishingToggleProbe() }
        func updateNSView(_ view: PublishingToggleProbe, context: Context) { view.choice = choice }
    }

    @MainActor private final class PublishingToggleProbe: NSView {
        var choice: Binding<Bool>?
    }
}
