import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

@MainActor
struct HistorySnapshotTests {
    @Test func indexedHistoryPreservesTheLegacyAgentRunDisplay() async throws {
        let spec = NodeSpec(id: "wn-GH-68", parent: nil, kind: .leaf, title: "Indexed history",
                            intent: "Keep complete agent history", acceptanceCriteria: ["All runs remain visible"])
        let ledger = try Ledger()
        let initial = try await ledger.append([
            LedgerEvent(node: spec.id, by: .reconciler, kind: .nodeCreated(spec: spec, ticket: "GH-68")),
            event(.runStarted(run: "author-1", role: .testAuthor), node: spec.id),
            event(.runFinished(run: "author-1", outcome: "acceptance tests committed"), node: spec.id),
            event(.runStarted(run: "builder-1", role: .implementer), node: spec.id),
            event(.runFinished(run: "builder-1", outcome: "submitted"), node: spec.id),
            event(.runStarted(run: "checker-1", role: .verifier), node: spec.id),
            event(.runFinished(run: "checker-1", outcome: "passed"), node: spec.id)
        ])
        let node = try #require(await ledger.workingState().nodes[spec.id])
        let legacy = HarnessViewModel()
        legacy.records = initial
        let before = try capture(node: node, model: legacy)
        try await ledger.append((0..<241).map { index in
            event(.runStarted(run: "unrelated-\(index)", role: .implementer), node: "other-node")
        })
        let indexed = HarnessViewModel()
        await indexed.refreshHistory(from: ledger)
        let after = try capture(node: node, model: indexed)
        let items = AgentRuns.runs(of: spec.id, in: indexed)
        #expect(items.map(\.run) == ["author-1", "builder-1"])
        #expect(items.map(\.outcome) == ["acceptance tests committed", "submitted"])
        #expect(AgentRuns.runs(of: spec.id, in: Array(indexed.records.suffix(200))).isEmpty)
        #expect(before.pixels == after.pixels)
        #expect(before.pixels.contains { $0 != before.pixels.first })

        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let evidence = root.appending(path: ".agentos-ui-evidence/GH-68", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try before.png.write(to: evidence.appending(path: "before.png"))
        try after.png.write(to: evidence.appending(path: "after.png"))
        let paths = [".agentos-ui-evidence/GH-68/before.png", ".agentos-ui-evidence/GH-68/after.png"]
        let metadata: [String: Any] = [
            "snapshotPaths": paths,
            "windowsOpened": before.opened && after.opened,
            "windowsClosed": before.closed && after.closed,
            "beforeScreenshot": paths[0],
            "afterScreenshot": paths[1]
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: ".agentos-ui-evidence.json"))
        let result: [String: Any] = [
            "test": "HistorySnapshotTests.indexedHistoryPreservesTheLegacyAgentRunDisplay",
            "captureMethod": "NSHostingView.cacheDisplay of actual AgentRuns content in opened AppKit windows",
            "comparison": "Complete legacy agent history versus indexed history after 241 unrelated events",
            "passed": before.pixels == after.pixels,
            "unrelatedNewerEvents": 241,
            "visibleRuns": items.map(\.run),
            "verifierExcluded": !items.contains { $0.role == .verifier },
            "windowsOpened": before.opened && after.opened,
            "windowsClosed": before.closed && after.closed
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appending(path: "snapshot-result.json"))
    }

    private func event(_ kind: EventKind, node: NodeID) -> LedgerEvent {
        LedgerEvent(node: node, by: .reconciler, kind: kind)
    }

    private struct Capture {
        let pixels: Data
        let png: Data
        let opened: Bool
        let closed: Bool
    }

    private func capture(node: NodeState, model: HarnessViewModel) throws -> Capture {
        _ = NSApplication.shared
        let view = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 8) {
                AgentRuns(node: node)
            }
            .padding(16)
            .frame(width: 720, height: 180, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(model)
        )
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 720, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.title = "GH-68 Agent runs"
        window.contentView = view
        defer { window.close() }
        window.orderFrontRegardless()
        #expect(window.isVisible)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let bytes = try #require(bitmap.bitmapData)
        let pixels = Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let opened = window.isVisible
        window.close()
        #expect(!window.isVisible)
        return Capture(pixels: pixels, png: png, opened: opened, closed: !window.isVisible)
    }
}
