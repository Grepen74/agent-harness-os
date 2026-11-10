import AppKit
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

struct RunningAgentsTests {
    @MainActor private func size(running since: Date, title: String, width: CGFloat) -> CGSize {
        let spec = NodeSpec(id: "wn-GH-12", parent: nil, kind: .leaf, title: title, intent: "I", acceptanceCriteria: ["a"])
        let node = NodeState(spec: spec, ticket: "GH-12", version: 1)
        let run = ActiveRun(run: "run-6d7689", role: .implementer, since: since)
        let row = RunRow(node: node, run: run, shown: .constant(nil)).environment(HarnessViewModel())
        return NSHostingController(rootView: row).sizeThatFits(in: CGSize(width: width, height: 100))
    }

    // A row that widens as its timer counts re-lays out the split view every second, which stalled the window.
    @MainActor @Test func rowWidthDoesNotChangeAsTheTimerCounts() {
        let title = "Rebase active leaves after catch-up"
        let justStarted = size(running: .now, title: title, width: 0)
        let anHourIn = size(running: .now.addingTimeInterval(-3725), title: title, width: 0)
        #expect(justStarted.width == anHourIn.width)
    }

    // Wider than the work pane's minimum (380) and the split view's dividers stick.
    @MainActor @Test func longTitleShrinksToFitTheWorkPane() {
        let title = String(repeating: "A very long ticket title ", count: 10)
        let width = size(running: .now, title: title, width: 0).width
        #expect(width > 100 && width <= 380)
    }

    @MainActor private func host(_ text: String, follows: Bool) -> (NSHostingView<LargeText>, NSTextView) {
        let view = NSHostingView(rootView: LargeText(text: text, follows: follows))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        view.layoutSubtreeIfNeeded()
        return (view, Self.textView(in: view)!)
    }

    @MainActor private static func textView(in view: NSView) -> NSTextView? {
        view as? NSTextView ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    private static func log(lines: Int) -> String {
        (1...lines).map { "line \($0): swift-testing ran a test and printed some output about it" }.joined(separator: "\n")
    }

    // Laying out a whole 200 KB log as one SwiftUI Text at every update froze the app while its log was open.
    @MainActor @Test func aLargeLogShowsAndUpdatesQuickly() {
        let start = ContinuousClock.now
        let (view, textView) = host(Self.log(lines: 3000), follows: true)
        view.rootView = LargeText(text: Self.log(lines: 3001), follows: true)
        view.layoutSubtreeIfNeeded()
        #expect(textView.string.hasSuffix("line 3001: swift-testing ran a test and printed some output about it"))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @MainActor @Test func followingKeepsTheEndInView() {
        let (view, textView) = host(Self.log(lines: 500), follows: true)
        view.rootView = LargeText(text: Self.log(lines: 600), follows: true)
        view.layoutSubtreeIfNeeded()
        let visible = textView.visibleRect
        #expect(visible.maxY >= textView.bounds.maxY - 1)
    }

    @MainActor @Test func notFollowingStaysAtTheTop() {
        let (view, textView) = host(Self.log(lines: 500), follows: false)
        view.rootView = LargeText(text: Self.log(lines: 600), follows: false)
        view.layoutSubtreeIfNeeded()
        #expect(textView.visibleRect.minY == 0)
    }
}
