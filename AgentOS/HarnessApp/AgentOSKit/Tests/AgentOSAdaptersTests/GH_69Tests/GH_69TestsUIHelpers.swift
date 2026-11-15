import AgentOSCore
import AgentOSTestSupport
import AgentOSUI
import AppKit
import Foundation
import Observation
import SwiftUI
import Testing

extension GH_69Tests {
    static func host<Content: View>(_ content: Content, interactive: Bool = false) -> (view: NSView, window: NSWindow) {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: Group {
            if interactive {
                content.buttonStyle(GH69ActionableButtonStyle())
            } else {
                content
            }
        }
            .frame(width: 1_100, height: 850)
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US")))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1_100, height: 850),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 1_100, height: 850)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(!window.isVisible)
        return (view, window)
    }

    static func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? [])
            + view.subviews.flatMap { Self.descendants($0, as: type) }
    }

    static func select(_ title: String, in popup: NSPopUpButton) throws {
        let item = try #require(popup.item(withTitle: title))
        #expect(item.isEnabled)
        let menu = try #require(popup.menu)
        if item.action != nil {
            menu.performActionForItem(at: menu.index(of: item))
        } else {
            popup.select(item)
            let action = try #require(popup.action)
            #expect(popup.sendAction(action, to: popup.target))
        }
    }

    static func select(_ title: String, filter: String, in view: NSView) throws {
        view.layoutSubtreeIfNeeded()
        let popup = try #require(Self.descendants(view, as: NSPopUpButton.self)
            .first { $0.itemTitles.contains(filter) })
        try Self.select(title, in: popup)
    }

    private static func accessibilityElements(
        in element: any NSAccessibilityProtocol
    ) -> [any NSAccessibilityProtocol] {
        [element] + (element.accessibilityChildren() ?? []).flatMap { child in
            (child as? any NSAccessibilityProtocol).map { Self.accessibilityElements(in: $0) } ?? []
        }
    }

    static func press(_ title: String, in view: NSView) throws {
        view.layoutSubtreeIfNeeded()
        if let bridge = Self.descendants(view, as: GH69ButtonActionView.self)
            .first(where: { RenderedUI.shows(title, in: $0.title) }) {
            try #require(bridge.isAccessibilityEnabled(), "\(title) must be enabled")
            try #require(bridge.accessibilityPerformPress(), "\(title) must accept a press")
            return
        }
        if let button = Self.descendants(view, as: NSButton.self).first(where: { $0.title == title }) {
            try #require(button.isEnabled, "\(title) must be enabled")
            button.performClick(nil)
            return
        }
        let button = try #require(Self.accessibilityElements(in: view).first {
            $0.accessibilityRole() == .button
                && ($0.accessibilityLabel() == title || $0.accessibilityTitle() == title)
        }, "The hosted view must expose an actionable \(title) button")
        try #require(button.isAccessibilityEnabled(), "\(title) must be enabled")
        try #require(button.accessibilityPerformPress(), "\(title) must accept a press")
    }

    static func scrollToLastLedgerRow(in view: NSView, count: Int) throws {
        view.layoutSubtreeIfNeeded()
        let table = try #require(Self.descendants(view, as: NSTableView.self)
            .first { $0.numberOfRows == count })
        table.scrollRowToVisible(count - 1)
        view.layoutSubtreeIfNeeded()
    }

    static func waitForPage(_ model: HarnessViewModel, until predicate: @escaping @MainActor () -> Bool) async throws {
        let (changes, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { signal.finish() }
        func observe() -> Bool {
            withObservationTracking {
                predicate()
            } onChange: {
                signal.yield(())
            }
        }
        if observe() { return }
        for await _ in changes {
            if observe() { return }
        }
        throw UIWaitFailure.pageDidNotUpdate
    }

    private enum UIWaitFailure: Error { case pageDidNotUpdate }

    static func imagePixels(_ view: NSView) throws -> Data {
        let image = try RenderedUI.image(of: view)
        let bytes = try #require(image.dataProvider?.data)
        return bytes as Data
    }

    // Hidden hosting views omit SwiftUI button accessibility on some macOS versions.
    // Keep the standard button rendering, but expose its public trigger to the test.
    private struct GH69ActionableButtonStyle: PrimitiveButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button(configuration)
                .buttonStyle(DefaultButtonStyle())
                .background(GH69ButtonActionBridge(label: configuration.label, action: configuration.trigger)
                    .allowsHitTesting(false))
        }
    }

    private struct GH69ButtonActionBridge<Label: View>: NSViewRepresentable {
        let label: Label
        let action: () -> Void
        @Environment(\.isEnabled) private var isEnabled

        func makeNSView(context: Context) -> GH69ButtonActionView {
            GH69ButtonActionView()
        }

        func updateNSView(_ view: GH69ButtonActionView, context: Context) {
            do {
                view.title = try RenderedUI.text(of: label, size: CGSize(width: 300, height: 40))
            } catch {
                Issue.record("Cannot read the SwiftUI button's label: \(error)")
            }
            view.setAccessibilityEnabled(isEnabled)
            view.action = action
        }
    }

    private final class GH69ButtonActionView: NSView {
        var title = ""
        var action: (() -> Void)?

        override func accessibilityPerformPress() -> Bool {
            guard isAccessibilityEnabled(), let action else { return false }
            action()
            return true
        }
    }
}
