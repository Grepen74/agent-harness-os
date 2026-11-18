import AgentOSUI
import AgentOSTestSupport
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentOSCore

extension GH_69Tests {
    @Test(arguments: ["paged", "filtered", "empty"])
    func ledgerPaneMatchesAnIndependentReferenceImage(state: String) async throws {
        let spec = NodeSpec(id: "wn-GH-69", parent: nil, kind: .leaf, title: "Ledger pane",
                            intent: "Show matching records", acceptanceCriteria: ["Retain row details"])
        let ledger = try Ledger()
        let all = try await ledger.append([
            LedgerEvent(node: spec.id, by: .reconciler, kind: .nodeCreated(spec: spec, ticket: "GH-69")),
        ] + (0..<405).map { index in
            LedgerEvent(node: "other", by: .adapter("ledger fixture"), kind: .attemptsReset,
                        at: Date(timeIntervalSince1970: Double(index)))
        } + [
            LedgerEvent(node: spec.id, by: .human("Ledger Reviewer"),
                        kind: .attemptFailed(summary: "Visible filtered failure")),
        ])
        let model = HarnessViewModel()
        let session = HarnessLedgerSession(view: model, source: ledger)
        await session.refresh()
        let node: NodeID? = state == "paged" ? nil : (state == "filtered" ? spec.id : "other")
        let kind: String? = state == "paged" ? nil : "attemptFailed"
        if let node { await model.ledgerPage.selectNode(node) }
        if kind != nil {
            await model.ledgerPage.selectKind(LedgerEventKind(.attemptFailed(summary: "filter")))
        }
        let referenceRecords: [RecordedEvent]
        switch state {
        case "paged": referenceRecords = Array(all.suffix(200).reversed())
        case "filtered": referenceRecords = [try #require(all.last)]
        default: referenceRecords = []
        }
        let actual = Self.host(LedgerPane().environment(model))
        defer { actual.window.close() }
        let actualImage = try Self.imagePixels(actual.view)
        actual.window.close()
        #expect(!actual.window.isVisible)

        // A frozen, independent layout is the image oracle, not a second LedgerPane or an OCR result.
        let reference = Self.host(GH69ReferenceLedgerPane(
            records: referenceRecords, total: all.count, node: node, kind: kind,
            canShowOlder: state == "paged", eventKinds: LedgerEventKind.allCases.map(\.rawValue)))
        defer { reference.window.close() }
        let referenceImage = try Self.imagePixels(reference.view)
        let referenceText = try RenderedUI.text(in: RenderedUI.image(of: reference.view)).joined(separator: "\n")
        #expect(RenderedUI.shows("Ledger", in: referenceText))
        #expect(RenderedUI.shows("\(all.count) records", in: referenceText))
        if state != "empty" {
            #expect(RenderedUI.shows(try #require(referenceRecords.first).event.kind.summary, in: referenceText))
        }
        #expect(referenceImage.contains { $0 != referenceImage.first })
        let imagesMatch = actualImage == referenceImage
        #expect(imagesMatch, "Ledger pane \(state) reference-image snapshot")
        reference.window.close()
        #expect(!reference.window.isVisible)
    }

    private struct GH69ReferenceLedgerPane: View {
        let records: [RecordedEvent]
        let total: Int
        let node: NodeID?
        let kind: String?
        let canShowOlder: Bool
        let eventKinds: [String]

        var body: some View {
            VSplitView {
                VStack(spacing: 0) {
                    Self.header("Ledger", "\(total) records. Append-only; the source of truth.")
                    HStack {
                        Button("Verify chain") {}
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.bottom, 6)
                    HStack {
                        Picker("Ticket", selection: Binding.constant(node)) {
                            Text("All tickets").tag(nil as NodeID?)
                            Text("GH-69").tag("wn-GH-69" as NodeID?)
                            Text("other").tag("other" as NodeID?)
                        }
                        Picker("Event kind", selection: Binding.constant(kind)) {
                            Text("All event kinds").tag(nil as String?)
                            ForEach(eventKinds, id: \.self) { name in
                                Text(name).tag(name as String?)
                            }
                        }
                        Spacer()
                        if canShowOlder { Button("Show older") {} }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 12).padding(.bottom, 6)
                    List(records) { record in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("#\(record.position)").monospaced().foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                            Image(systemName: Self.icon(record.event.by)).frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.event.kind.summary).lineLimit(2)
                                Text("\(record.event.by.label) \u{00b7} \(Self.nodeName(record.event.node)) \u{00b7} \(record.hash.prefix(10)) \u{00b7} \(record.event.at.formatted(date: .numeric, time: .standard))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
                .frame(minHeight: 300)
                VStack(spacing: 0) {
                    Self.header("Harness activity", "What each reconciler round did.")
                    List(Array([String]().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
                .frame(minHeight: 140)
            }
        }

        private static func header(_ title: String, _ subtitle: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }

        private static func nodeName(_ node: NodeID?) -> String {
            switch node {
            case "wn-GH-69": "GH-69"
            case .some(let id): id
            case nil: "\u{2013}"
            }
        }

        private static func icon(_ participant: Participant) -> String {
            switch participant {
            case .human: "person.fill"
            case .agent: "cpu"
            case .reconciler: "arrow.triangle.2.circlepath"
            case .adapter: "antenna.radiowaves.left.and.right"
            }
        }
    }
}
