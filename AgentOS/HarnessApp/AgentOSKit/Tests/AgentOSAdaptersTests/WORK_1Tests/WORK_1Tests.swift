// API contract: each ticket and node VSplitView row must remain vertically flexible when its content is empty.

import Foundation
import Testing

@Suite
struct WORK_1Tests {
    @Test
    func emptyTicketPaneRowsRemainDraggable() throws {
        let source = try paneSource(named: "TrackerPane")

        #expect(source.contains(".frame(minHeight:180,maxHeight:.infinity)"))
        #expect(source.contains(".frame(minHeight:260,maxHeight:.infinity)"))
    }

    @Test
    func emptyNodePaneRowsRemainDraggable() throws {
        let source = try paneSource(named: "WorkPane")

        #expect(source.contains(".frame(minHeight:260,maxHeight:.infinity)"))
        #expect(source.contains(".frame(minHeight:160,maxHeight:.infinity)"))
    }

    private func paneSource(named name: String) throws -> String {
        let agentOSKit = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = agentOSKit
            .appending(path: "Sources/AgentOSUI")
            .appending(path: "\(name).swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
            .filter { !$0.isWhitespace }
    }
}
