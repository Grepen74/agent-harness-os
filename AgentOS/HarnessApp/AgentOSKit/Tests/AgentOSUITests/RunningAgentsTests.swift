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
}
