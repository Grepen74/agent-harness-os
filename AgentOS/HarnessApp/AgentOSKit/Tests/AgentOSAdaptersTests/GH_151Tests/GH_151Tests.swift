// Expected API: EventKind.testsRecorded(files: [String], suite: String) records the tests
// displayed by NodeDetail(node:). Existing Ledger and HarnessViewModel.state/config supply
// the shared work-pane detail in repository (configured) and simulator (unconfigured) windows.
// Criterion 5's exact row-label-list edits and preservation of all other assertions in
// GH_75Tests and GH_142Tests are source-only checks for the reviewer, not source-text tests.
import AgentOSTestSupport
import Foundation
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

@Suite @MainActor struct GH_151Tests {
    @Test(arguments: WindowContext.allCases)
    func nodeDetailsReplaceTestTargetWithTestSuiteAndTestFiles(context: WindowContext) async throws {
        let image = try await Self.detailImage(context: context)
        let text = try RenderedUI.text(in: image).joined(separator: "\n")

        #expect(RenderedUI.shows("Test suite", in: text))
        #expect(RenderedUI.shows("Test files", in: text))
        #expect(!RenderedUI.shows("Test target", in: text))
    }

    @Test(arguments: WindowContext.allCases)
    func recordedLeafShowsItsRecordedSuiteAndEveryFileOnSeparateLines(context: WindowContext) async throws {
        let files = [
            "\(context.folder)/Zebra.swift",
            "\(context.folder)/Alpha.swift",
            "\(context.folder)/Fixtures.swift",
        ]
        let image = try await Self.detailImage(
            context: context, record: TestRecord(files: files, suite: "LeafContractTests"))
        let suite = try Self.rowText("Test suite", in: image)

        #expect(RenderedUI.shows("LeafContractTests", in: suite))
        #expect(!RenderedUI.shows(Self.spec.testTarget, in: suite),
                "A recorded suite takes precedence over the ticket-derived suite.")
        try Self.expectSeparateLines(files, in: Self.rowImage("Test files", in: image))
    }

    @Test(arguments: WindowContext.allCases)
    func unrecordedLeafShowsItsSpecSuiteAndItsWindowSpecificFolderWithTrailingSlash(
        context: WindowContext
    ) async throws {
        let image = try await Self.detailImage(context: context)
        let suite = try Self.rowText("Test suite", in: image)
        let files = try Self.rowText("Test files", in: image)

        #expect(RenderedUI.shows(Self.spec.testTarget, in: suite))
        #expect(RenderedUI.shows(context.folder + "/", in: files),
                "Show the leaf's folder, including its trailing slash, rather than inventing a file.")
    }

    @Test(arguments: WindowContext.allCases, [false, true])
    func compositeShowsDashesInsteadOfASuiteOrFiles(context: WindowContext, hasRecord: Bool) async throws {
        let record = hasRecord
            ? TestRecord(files: ["\(context.folder)/Zebra.swift"], suite: "LeafContractTests")
            : nil
        let image = try await Self.detailImage(context: context, kind: .composite, record: record)

        try Self.expectDash(row: "Test suite", in: image)
        try Self.expectDash(row: "Test files", in: image)
    }

    @Test
    func rowReaderRecognizesExistingValuesSeparateLinesAndAnEmptyValue() async throws {
        let image = try await Self.detailImage(context: .simulator)

        #expect(RenderedUI.shows("Storage", in: try Self.rowText("Touches", in: image)))
        try Self.expectSeparateLines(
            ["Sources/Store.swift", "Resources/Greetings"],
            in: Self.rowImage("Paths", in: image))
        try Self.expectDash(row: "Landed at", in: image)
    }

    @Test(arguments: ["LeafContractTests", "–"])
    func rowReaderIsolatesARowBetweenMultilineValues(suiteValue: String) throws {
        let files = [
            "Quality/Acceptance/GH_151Tests/Zebra.swift",
            "Quality/Acceptance/GH_151Tests/Alpha.swift",
            "Quality/Acceptance/GH_151Tests/Fixtures.swift",
        ]
        let view = Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            GridRow {
                Text("Paths")
                Text("Sources/Store.swift\nResources/Greetings")
            }
            GridRow {
                Text("Test suite")
                Text(suiteValue)
            }
            GridRow {
                Text("Test files")
                Text(files.joined(separator: "\n"))
            }
            GridRow {
                Text("Landed at")
                Text("–")
            }
        }
        .font(.caption)
        .frame(width: 800, height: 650).scaleEffect(2)
        .frame(width: 1600, height: 1300)
        let image = try RenderedUI.image(of: view, size: CGSize(width: 1600, height: 1300))
        let suite = try Self.rowText("Test suite", in: image)

        if suiteValue == "–" {
            try Self.expectDash(row: "Test suite", in: image)
        } else {
            #expect(RenderedUI.shows(suiteValue, in: suite))
        }
        #expect(!RenderedUI.shows("Resources/Greetings", in: suite))
        #expect(!RenderedUI.shows("Zebra.swift", in: suite))
        try Self.expectSeparateLines(files, in: Self.rowImage("Test files", in: image))
        try Self.expectDash(row: "Landed at", in: image)
    }

    private static var spec: NodeSpec {
        var spec = NodeSpec(
            id: "wn-GH-151", kind: .leaf, title: "Store greeting", intent: "Keep a greeting",
            acceptanceCriteria: ["A greeting is stored"])
        spec.touches = ["Storage"]
        spec.predictedPaths = ["Sources/Store.swift", "Resources/Greetings"]
        return spec
    }

    private struct TestRecord {
        let files: [String]
        let suite: String
    }

    enum WindowContext: CaseIterable, Sendable {
        case repository, simulator

        var config: RepoConfig? {
            switch self {
            case .repository:
                RepoConfig(test: .init(command: "swift test"),
                           leafTests: .init(target: "AcceptanceTests", folder: "Quality/Acceptance"))
            case .simulator:
                nil
            }
        }

        var folder: String {
            switch self {
            case .repository: "Quality/Acceptance/GH_151Tests"
            case .simulator: "Tests/GH_151Tests"
            }
        }
    }

    private static func detailImage(
        context: WindowContext, kind: NodeKind = .leaf, record: TestRecord? = nil
    ) async throws -> CGImage {
        var spec = Self.spec
        spec.kind = kind
        let ledger = try Ledger()
        try await ledger.append([
            LedgerEvent(node: spec.id, by: .reconciler,
                        kind: .nodeCreated(spec: spec, ticket: "GH-151")),
        ])
        if let record {
            try await ledger.append([
                LedgerEvent(node: spec.id, by: .agent(run: "test-author", role: .testAuthor),
                            kind: .testsRecorded(files: record.files, suite: record.suite)),
            ])
        }
        let model = HarnessViewModel()
        model.config = context.config
        model.state = await ledger.workingState()
        let node = try #require(model.state.nodes[spec.id])
        let view = NodeDetail(node: node).environment(model)
            .frame(width: 800, height: 650).scaleEffect(2)
            .frame(width: 1600, height: 1300)
        return try RenderedUI.image(of: view, size: CGSize(width: 1600, height: 1300))
    }

    private static func rowText(_ label: String, in image: CGImage) throws -> String {
        try RenderedUI.text(in: Self.rowImage(label, in: image)).joined(separator: "\n")
    }

    private static func rowImage(_ label: String, in image: CGImage) throws -> CGImage {
        let lines = try RenderedUI.lines(in: image)
        let labels = [
            "Ticket", "Phase", "Gates", "Links", "Touches", "Paths",
            "Test suite", "Test files", "Test target", "Affected tests",
            "Attempts failed", "Reworks", "Landed at", "Tests fingerprint", "Spec hash",
        ]
        var boxes: [String: CGRect] = [:]
        for line in lines {
            for title in labels where line.text.range(of: title, options: [.anchored, .caseInsensitive]) != nil {
                boxes[title] = line.box
            }
        }
        let text = lines.map(\.text).joined(separator: "\n")
        let box = try #require(boxes[label], "Missing \(label) row in:\n\(text)")
        // Centered multiline rows extend beyond their label boxes. The widest blank
        // band between label centers is the grid's row gap, not a gap inside a value.
        let height = CGFloat(image.height)
        let center = (1 - box.midY) * height
        let previous = boxes.values.filter { $0.midY > box.midY }.map(\.midY).min()
        let next = boxes.values.filter { $0.midY < box.midY }.map(\.midY).max()
        let top = try previous.map {
            try Self.rowBoundary(from: (1 - $0) * height, to: center, in: image)
        } ?? 0
        let bottom = try next.map {
            try Self.rowBoundary(from: center, to: (1 - $0) * height, in: image)
        } ?? height
        let rect = CGRect(
            x: 0, y: top,
            width: CGFloat(image.width), height: bottom - top).integral
        return try #require(image.cropping(to: rect))
    }

    private static func rowBoundary(from top: CGFloat, to bottom: CGFloat, in image: CGImage) throws -> CGFloat {
        var runStart = Int(top.rounded(.up))
        var widest: Range<Int> = runStart..<runStart
        for y in runStart..<Int(bottom.rounded(.down)) {
            let strip = try #require(image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: 1)))
            if RenderedUI.inkRect(of: strip) == nil {
                if y + 1 - runStart > widest.count { widest = runStart..<(y + 1) }
            } else {
                runStart = y + 1
            }
        }
        try #require(!widest.isEmpty, "No blank row boundary between \(top) and \(bottom)")
        return CGFloat(widest.lowerBound + widest.upperBound) / 2
    }

    private static func expectSeparateLines(_ entries: [String], in image: CGImage) throws {
        let lines = try RenderedUI.lines(in: image)
        let text = lines.map(\.text).joined(separator: "\n")
        let values = try entries.map { entry in
            try #require(lines.first { RenderedUI.shows(entry, in: $0.text) }, "Missing \(entry) in:\n\(text)")
        }
        for (index, line) in values.enumerated() {
            for other in values.dropFirst(index + 1) {
                #expect(abs(line.box.midY - other.box.midY) > 0.5 * min(line.box.height, other.box.height),
                        "Each file must occupy its own line:\n\(text)")
            }
        }
    }

    private static func expectDash(row label: String, in image: CGImage) throws {
        let row = try Self.rowImage(label, in: image)
        let lines = try RenderedUI.lines(in: row)
        let text = lines.map(\.text).joined(separator: "\n")
        if ["–", "—", "-"].contains(where: { RenderedUI.shows("\(label) \($0)", in: text) }) { return }
        let labelLine = try #require(lines.first { RenderedUI.shows(label, in: $0.text) },
                                     "Missing \(label) in:\n\(text)")
        #expect(lines.allSatisfy { RenderedUI.shows($0.text, in: label) },
                "Show only an empty-value dash beside \(label):\n\(text)")
        // Vision can omit a lone dash; check the short, flat mark beside the label.
        let width = CGFloat(row.width), height = CGFloat(row.height)
        let labelHeight = labelLine.box.height * height
        let valueX = (labelLine.box.maxX * width).rounded(.up) + 8
        let area = CGRect(
            x: valueX, y: (1 - labelLine.box.maxY) * height,
            width: width - valueX, height: labelHeight).integral
        let value = try #require(row.cropping(to: area))
        let mark = try #require(RenderedUI.inkRect(of: value), "Expected a dash, not a blank row:\n\(text)")
        #expect(mark.width > 1.5 * mark.height && mark.height < 0.5 * labelHeight,
                "The empty-value mark is not dash-shaped: \(mark.size)")
    }
}
