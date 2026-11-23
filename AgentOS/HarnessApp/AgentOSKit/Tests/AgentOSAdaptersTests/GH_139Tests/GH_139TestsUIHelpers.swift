import AgentOSTestSupport
import AppKit
import SwiftUI
import Testing

extension GH_139Tests {
    static func interactiveHost<Content: View>(_ content: Content) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: content
            .buttonStyle(ActionableButtons())
            .frame(width: Self.paneSize.width, height: Self.paneSize.height)
            .environment(\.colorScheme, .light))
        host.frame = CGRect(origin: .zero, size: Self.paneSize)
        return host
    }

    static func pressClearFilter(in view: NSView) throws {
        let button = try #require(Self.buttons(in: view).first {
            RenderedUI.shows("Clear stage filter", in: $0.title)
        }, "The visible clear-filter button must be actionable")
        #expect(button.accessibilityPerformPress())
    }

    static func verifyButtonBridge() throws {
        var presses = 0
        let probe = Self.interactiveHost(Button("GH139 control probe") { presses += 1 })
        let text = try RenderedUI.text(in: RenderedUI.image(of: probe)).joined(separator: "\n")
        try #require(RenderedUI.shows("GH139 control probe", in: text))
        let button = try #require(Self.buttons(in: probe).first {
            RenderedUI.shows("GH139 control probe", in: $0.title)
        })
        try #require(button.accessibilityPerformPress())
        try #require(presses == 1, "Validate the action bridge against a standard SwiftUI Button")
    }

    private static func buttons(in view: NSView) -> [ButtonActionView] {
        ((view as? ButtonActionView).map { [$0] } ?? []) + view.subviews.flatMap { Self.buttons(in: $0) }
    }

    // Hidden windows do not consistently expose SwiftUI's own button accessibility.
    private struct ActionableButtons: PrimitiveButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button(configuration)
                .buttonStyle(DefaultButtonStyle())
                .background(ButtonBridge(label: configuration.label, action: configuration.trigger).allowsHitTesting(false))
        }
    }

    private struct ButtonBridge<Label: View>: NSViewRepresentable {
        let label: Label
        let action: () -> Void
        @Environment(\.isEnabled) private var isEnabled

        func makeNSView(context: Context) -> ButtonActionView { ButtonActionView() }

        func updateNSView(_ view: ButtonActionView, context: Context) {
            do {
                view.title = try RenderedUI.text(of: label, size: CGSize(width: 320, height: 40))
            } catch {
                Issue.record("Cannot read the clear-filter control: \(error)")
            }
            view.setAccessibilityEnabled(isEnabled)
            view.action = action
        }
    }

    private final class ButtonActionView: NSView {
        var title = ""
        var action: (() -> Void)?

        override func accessibilityPerformPress() -> Bool {
            guard isAccessibilityEnabled(), let action else { return false }
            action()
            return true
        }
    }
}
