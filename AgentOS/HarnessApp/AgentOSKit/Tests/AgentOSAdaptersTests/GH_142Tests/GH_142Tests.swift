// Expected API: ChildProposal.affectedTests: [String]? and NodeSpec.affectedTests: [String] (default []).
// Existing reconciler APIs post the preview, Broken down and No breakdown needed comments;
// NodeDetail(node:) renders the Work pane detail from ledger-derived NodeState.
// Criterion 3 (README.md and docs/real-repo-mode.md explaining where affected tests appear
// before breakdown approval) is documentation-only and is checked by the reviewer, not a test.
import AgentOSTestSupport
import Foundation
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

@Suite struct GH_142Tests {
    @Test
    func previewListsEachChildsAffectedTestsAtTheEndOfItsLine() async throws {
        let fixture = try Fixture(children: Self.children)
        let comment = try await fixture.preview()

        try Self.expectChildLines(in: comment)
    }

    @Test(arguments: LeafTests.allCases)
    func singleLeafPreviewShowsAffectedTestsOnlyWhenPresent(tests: LeafTests) async throws {
        let fixture = try Fixture(children: [Self.proposal("Store greeting", tests: tests.entries)])
        let comment = try await fixture.preview()

        try Self.expectAffectedTests(tests.entries, on: Self.leafLine(in: comment))
    }

    @Test(arguments: [false, true])
    func brokenDownCommentListsEachChildsAffectedTestsAtTheEndOfItsLine(acceptPreview: Bool) async throws {
        let fixture = try Fixture(children: Self.children)
        if acceptPreview { _ = try await fixture.preview() }
        let comment = try await fixture.breakDown(commentContaining: "Broken down")

        try Self.expectChildLines(in: comment)
    }

    @Test(arguments: [false, true], LeafTests.allCases)
    func noBreakdownNeededCommentShowsAffectedTestsOnlyWhenPresent(
        acceptPreview: Bool, tests: LeafTests
    ) async throws {
        let fixture = try Fixture(children: [Self.proposal("Store greeting", tests: tests.entries)])
        if acceptPreview { _ = try await fixture.preview() }
        let comment = try await fixture.breakDown(commentContaining: "No breakdown needed")

        try Self.expectAffectedTests(tests.entries, on: Self.leafLine(in: comment))
    }

    @MainActor @Test(arguments: [NodeKind.leaf, .composite])
    func workPaneListsEachAffectedTestOnItsOwnLine(kind: NodeKind) async throws {
        let image = try await Self.detailImage(affectedTests: Self.affectedTests, kind: kind)
        let row = try Self.rowImage("Affected tests", in: image)

        try Self.expectSeparateLines(Self.affectedTests, in: row)
    }

    @MainActor @Test(arguments: [NodeKind.leaf, .composite])
    func workPaneShowsADashWhenThereAreNoAffectedTests(kind: NodeKind) async throws {
        let image = try await Self.detailImage(affectedTests: [], kind: kind)

        try Self.expectDash(row: "Affected tests", in: image)
    }

    @MainActor @Test
    func rowReaderRecognizesExistingMultilineAndEmptyValues() async throws {
        let image = try await Self.detailImage(affectedTests: [])
        let touches = try RenderedUI.text(in: Self.rowImage("Touches", in: image)).joined(separator: "\n")
        #expect(RenderedUI.shows("Storage", in: touches))
        try Self.expectSeparateLines(
            ["Sources/Store.swift", "Resources/Greetings"],
            in: Self.rowImage("Paths", in: image))
        try Self.expectDash(row: "Landed at", in: image)
    }

    enum LeafTests: CaseIterable, Sendable {
        case omitted, empty, populated

        var entries: [String]? {
            switch self {
            case .omitted: nil
            case .empty: []
            case .populated: GH_142Tests.affectedTests
            }
        }
    }

    private static func expectChildLines(in comment: String) throws {
        for child in Self.children {
            let line = try #require(comment.components(separatedBy: "\n").first {
                $0.contains(child.title) && $0.contains("touches")
            }, "Missing child \(child.title) in:\n\(comment)")
            try Self.expectAffectedTests(child.affectedTests, on: line)
        }
    }

    private static func leafLine(in comment: String) throws -> String {
        try #require(comment.components(separatedBy: "\n").first { $0.contains("touches") },
                     "Missing the single-leaf description in:\n\(comment)")
    }

    private static func expectAffectedTests(_ tests: [String]?, on line: String) throws {
        let entries = tests ?? []
        if entries.isEmpty {
            #expect(!line.contains("affected tests:"), "An unaffected child has no affected-tests suffix:\n\(line)")
        } else {
            let suffix = "  affected tests: " + entries.joined(separator: ", ")
            #expect(line.hasSuffix(suffix), "The child's line must end with \(suffix.debugDescription):\n\(line)")
        }
    }
}
