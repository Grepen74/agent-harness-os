// API contract: Ledger is a LedgerPageSource with a stable ledgerID and bounded pageSnapshot.
// LedgerEventKind identifies EventKind cases without their payloads. HarnessViewModel.refreshLedger
// refreshes a separate LedgerPageModel whose awaited filter/paging actions finish their refresh.
// Complete legacy/indexed history still uses refreshHistory, records, and records(for:).
// HarnessLedgerSession is the shared production refresh/replacement bridge used by both app models.
// Its refresh source also offers records(after:limit:) for bounded, exclusive-position history transfer.
// LedgerPane renders ticket/kind pickers and a Show older button; actions refresh its page.

import AgentOSAdapters
import AgentOSTestSupport
import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import AgentOSCore
@testable import AgentOSUI

@Suite(.serialized) @MainActor struct GH_69Tests {
    @Test(arguments: [0, 1, 199, 200, 201, 400, 401, 605])
    func newestRecordsHaveTwoHundredRecordPageBoundaries(count: Int) async throws {
        let ledger = try Ledger()
        let all = try await ledger.append(Self.events(count: count))
        let model = HarnessViewModel()
        await model.refreshLedger(from: ledger)

        #expect(model.ledgerPage.limit == 200)
        Self.expectPage(model, all: all, matching: all, limit: 200)
        var limit = 200
        for _ in 0..<(max(0, count - 1) / 200) {
            #expect(model.ledgerPage.canShowOlder)
            await model.ledgerPage.showOlder()
            limit += 200
            #expect(model.ledgerPage.limit == limit)
            Self.expectPage(model, all: all, matching: all, limit: limit)
        }
        #expect(!model.ledgerPage.canShowOlder)
        #expect(model.ledgerPage.records.count == count)
    }

    @Test
    func refreshPreservesTheLimitAndEitherFilterChangeResetsItWithoutStaleRows() async throws {
        let ledger = try Ledger()
        var all = try await ledger.append(Self.events(count: 630))
        let model = HarnessViewModel()
        await model.refreshLedger(from: ledger)
        await model.ledgerPage.showOlder()
        all += try await ledger.append(Self.events(count: 11, node: "new-node"))
        await model.refreshLedger(from: ledger)
        #expect(model.ledgerPage.limit == 400)
        Self.expectPage(model, all: all, matching: all, limit: 400)

        await model.ledgerPage.selectNode(Self.node)
        #expect(model.ledgerPage.limit == 200)
        Self.expectPage(model, all: all, matching: all.filter { $0.event.node == Self.node }, limit: 200)
        await model.ledgerPage.showOlder()
        #expect(model.ledgerPage.limit == 400)
        await model.ledgerPage.selectKind(LedgerEventKind(.attemptFailed(summary: "any payload")))
        #expect(model.ledgerPage.limit == 200)
        Self.expectPage(model, all: all, matching: [], limit: 200)
        #expect(!model.ledgerPage.canShowOlder)

        await model.ledgerPage.selectKind(nil)
        #expect(model.ledgerPage.limit == 200)
        #expect(!model.ledgerPage.records.isEmpty)
        await model.ledgerPage.selectNode("absent-node")
        Self.expectPage(model, all: all, matching: [], limit: 200)
        await model.ledgerPage.selectNode(nil)
        Self.expectPage(model, all: all, matching: all, limit: 200)
    }

    @Test
    func ticketChoicesIncludeLedgerOnlyNodesAndUseCanonicalNamesWithExactNodeMatching() async throws {
        let ledger = try Ledger()
        let spec = NodeSpec(id: Self.node, parent: nil, kind: .composite, title: "Parent",
                            intent: "Filter exactly", acceptanceCriteria: ["Do not include children"])
        let child = NodeSpec(id: "child-node", parent: spec.id, kind: .leaf, title: "Child",
                             intent: "Separate history", acceptanceCriteria: ["Its own events"])
        let all = try await ledger.append([
            Self.event(.nodeCreated(spec: spec, ticket: "GH-69"), node: spec.id),
            Self.event(.nodeCreated(spec: child, ticket: "GH-70"), node: child.id),
            Self.event(.attemptsReset, node: spec.id),
            Self.event(.attemptsReset, node: child.id),
            Self.event(.attemptsReset, node: "ledger-only-node"),
            Self.event(.attemptsReset, node: nil),
        ])
        let model = HarnessViewModel()
        model.tickets = []
        model.state = await ledger.workingState()
        await model.refreshLedger(from: ledger)
        #expect(Set(model.ledgerPage.nodeIDs) == Set([spec.id, child.id, "ledger-only-node"]))
        #expect(model.ledgerPage.nodeIDs.count == 3)
        #expect(model.ledgerNodeLabel(spec.id) == NodeIdentity(ticketKey: "GH-69", nodeID: spec.id).displayName)
        #expect(model.ledgerNodeLabel(child.id) == NodeIdentity(ticketKey: "GH-70", nodeID: child.id).displayName)
        #expect(model.ledgerNodeLabel("ledger-only-node") == "ledger-only-node")

        await model.ledgerPage.selectNode(spec.id)
        Self.expectPage(model, all: all, matching: [all[0], all[2]], limit: 200)
        await model.ledgerPage.selectNode("ledger-only-node")
        Self.expectPage(model, all: all, matching: [all[4]], limit: 200)
        await model.ledgerPage.selectNode(nil)
        Self.expectPage(model, all: all, matching: all, limit: 200)
        #expect(model.ledgerPage.records.contains { $0.event.node == nil })
    }

    @Test
    func filtersCombineBeforePagingSoOlderPayloadIndependentMatchesRemainDiscoverable() async throws {
        let ledger = try Ledger()
        let older = (0..<405).map { index in
            Self.event(.attemptFailed(summary: "older failure \(index)"), node: Self.node)
        }
        let noise = Self.events(count: 450, node: Self.node)
            + (0..<250).map { Self.event(.attemptFailed(summary: "other failure \($0)"), node: "other") }
        let all = try await ledger.append(older + noise)
        let model = HarnessViewModel()
        await model.refreshLedger(from: ledger)
        await model.ledgerPage.selectNode(Self.node)
        await model.ledgerPage.selectKind(LedgerEventKind(.attemptFailed(summary: "unseen payload")))

        let matching = Array(all.prefix(405))
        Self.expectPage(model, all: all, matching: matching, limit: 200)
        await model.ledgerPage.showOlder()
        Self.expectPage(model, all: all, matching: matching, limit: 400)
        await model.ledgerPage.showOlder()
        Self.expectPage(model, all: all, matching: matching, limit: 600)
        #expect(model.ledgerPage.records.last?.event.id == older.first?.id)
        await model.ledgerPage.selectNode(nil)
        Self.expectPage(model, all: all,
                        matching: all.filter { if case .attemptFailed = $0.event.kind { true } else { false } },
                        limit: 200)
    }

    @Test
    func ticketOptionsIncludeNodesWhoseOnlyRecordsAreOutsideTheDisplayedPage() async throws {
        let ledger = try Ledger()
        let all = try await ledger.append([
            Self.event(.attemptFailed(summary: "old orphan event"), node: "old-ledger-only-node"),
            Self.event(.attemptsReset, node: nil),
        ] + Self.events(count: 230, node: "recent-node"))
        let snapshot = await ledger.pageSnapshot(node: nil, kind: nil, limit: 200)
        #expect(Set(snapshot.nodeIDs) == Set(["old-ledger-only-node", "recent-node"]))
        #expect(snapshot.records.allSatisfy { $0.event.node == "recent-node" })
        let model = HarnessViewModel()
        await model.refreshLedger(from: ledger)
        #expect(Set(model.ledgerPage.nodeIDs) == Set(snapshot.nodeIDs))
        await model.ledgerPage.selectNode("old-ledger-only-node")
        Self.expectPage(model, all: all, matching: [all[0]], limit: 200)
        #expect(Set(model.ledgerPage.nodeIDs) == Set(snapshot.nodeIDs))
    }

    @Test
    func eventKindChoicesRepresentEveryCaseOnceAndIgnoreAssociatedValues() async throws {
        let ledger = try Ledger()
        let events = [
            Self.event(.flagSet(.blocked, reason: "first")),
            Self.event(.flagSet(.needsInput, reason: "second")),
            Self.event(.runStarted(run: "builder", role: .implementer)),
            Self.event(.runStarted(run: "author", role: .testAuthor)),
            Self.event(.attemptsReset, node: nil),
        ]
        let all = try await ledger.append(events)
        let model = HarnessViewModel()
        await model.refreshLedger(from: ledger)
        let choices = model.ledgerPage.eventKinds.map(\.rawValue)
        #expect(choices.count == Set(choices).count)
        #expect(Set(choices) == Set(Self.existingEventCaseNames))
        #expect(Set(LedgerEventKind.allCases.map(\.rawValue)) == Set(Self.existingEventCaseNames))
        #expect(LedgerEventKind(events[0].kind) == LedgerEventKind(events[1].kind))
        #expect(LedgerEventKind(events[2].kind) == LedgerEventKind(events[3].kind))
        #expect(LedgerEventKind(events[0].kind) != LedgerEventKind(events[2].kind))
        await model.ledgerPage.selectKind(LedgerEventKind(events[0].kind))
        Self.expectPage(model, all: all, matching: Array(all.prefix(2)), limit: 200)
        await model.ledgerPage.selectKind(LedgerEventKind(.attemptsReset))
        Self.expectPage(model, all: all, matching: [all[4]], limit: 200)
        await model.ledgerPage.selectNode(Self.node)
        Self.expectPage(model, all: all, matching: [], limit: 200)
        await model.ledgerPage.selectKind(nil)
        Self.expectPage(model, all: all, matching: Array(all.prefix(4)), limit: 200)
    }

    @Test
    func everyRealEventCaseMapsToItsOwnFilterAndFindsOlderRecords() async throws {
        let kinds = Self.representativeEventKinds()
        let names = try kinds.map { kind -> String in
            let object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(kind)) as? [String: Any])
            #expect(object.count == 1)
            return try #require(object.keys.first)
        }
        #expect(Set(names) == Set(Self.existingEventCaseNames))
        #expect(names.count == Self.existingEventCaseNames.count)
        let ledger = try Ledger()
        let all = try await ledger.append(kinds.map { Self.event($0) }
            + kinds.map { Self.event($0, node: "other") }
            + Self.events(count: 250, node: "recent-noise"))
        let model = HarnessViewModel()
        await model.refreshLedger(from: ledger)
        for (index, kind) in kinds.enumerated() {
            let choice = LedgerEventKind(kind)
            #expect(choice.rawValue == names[index])
            await model.ledgerPage.selectKind(choice)
            let expected = all.filter { LedgerEventKind($0.event.kind).rawValue == names[index] }
            // Expectations come from the real enum's encoded case, not the mapping under test.
            let independent = try all.filter { record in
                let object = try #require(
                    JSONSerialization.jsonObject(with: JSONEncoder().encode(record.event.kind)) as? [String: Any])
                return object.keys.contains(names[index])
            }
            #expect(expected.map(\.event.id) == independent.map(\.event.id))
            Self.expectPage(model, all: all, matching: independent, limit: 200)
            await model.ledgerPage.selectNode(Self.node)
            Self.expectPage(model, all: all, matching: [all[index]], limit: 200)
            await model.ledgerPage.selectNode(nil)
        }
    }

    @Test
    func snapshotsAreBoundedAndImmutableWithExactCountsAndOriginalRowData() async throws {
        let ledger = try Ledger()
        let initial = try await ledger.append(Self.events(count: 735))
        let snapshot = await ledger.pageSnapshot(node: Self.node, kind: nil, limit: 200)
        #expect(snapshot.ledgerID == ledger.ledgerID)
        #expect(snapshot.totalCount == 735)
        #expect(snapshot.matchingCount == 735)
        #expect(snapshot.records.count == 200)
        #expect(snapshot.records.map(\.position) == Array(initial.suffix(200).reversed()).map(\.position))
        #expect(snapshot.records.map(\.hash) == Array(initial.suffix(200).reversed()).map(\.hash))
        #expect(snapshot.records.map(\.event.by) == Array(initial.suffix(200).reversed()).map(\.event.by))
        #expect(snapshot.records.map { $0.event.kind.summary }
                == Array(initial.suffix(200).reversed()).map { $0.event.kind.summary })

        let tail = try await ledger.append([Self.event(.attemptFailed(summary: "new global failure"), node: nil)])
        #expect(snapshot.totalCount == 735)
        #expect(snapshot.records.first?.event.id == initial.last?.event.id)
        let filtered = await ledger.pageSnapshot(
            node: nil, kind: LedgerEventKind(.attemptFailed(summary: "different")), limit: 200)
        #expect(filtered.totalCount == 736)
        #expect(filtered.matchingCount == 1)
        #expect(filtered.records.map(\.event.id) == tail.map(\.event.id))
    }

    @Test
    func liveAppendsAndRepeatedRefreshesNeverLoseOrDuplicateMatchingRecords() async throws {
        let ledger = try Ledger()
        var all = try await ledger.append(Self.events(count: 395))
        let model = HarnessViewModel()
        await model.refreshLedger(from: ledger)
        await model.ledgerPage.selectNode(Self.node)
        await model.ledgerPage.showOlder()
        for count in [1, 5, 201] {
            let events = Self.events(count: count)
                + [Self.event(.attemptsReset, node: nil), Self.event(.attemptsReset, node: "other")]
            all += try await ledger.append(events)
            #expect(try await ledger.append(events).isEmpty)
            await model.refreshLedger(from: ledger)
            await model.refreshLedger(from: ledger)
            Self.expectPage(model, all: all, matching: all.filter { $0.event.node == Self.node }, limit: 400)
        }
        await model.ledgerPage.showOlder()
        await model.ledgerPage.showOlder()
        let matching = all.filter { $0.event.node == Self.node }
        Self.expectPage(model, all: all, matching: matching, limit: 800)
        #expect(Set(model.ledgerPage.records.map(\.event.id)) == Set(matching.map(\.event.id)))
    }

    @Test
    func refreshPreservesCombinedFiltersAndExpandedLimitAfterMatchingAndNonmatchingAppends() async throws {
        let ledger = try Ledger()
        var all = try await ledger.append(
            (0..<405).map { Self.event(.attemptFailed(summary: "older failure \($0)")) }
                + Self.events(count: 450))
        var matching = Array(all.prefix(405))
        let model = HarnessViewModel()
        let session = HarnessLedgerSession(view: model, source: ledger)
        await session.refresh()
        await model.ledgerPage.selectNode(Self.node)
        await model.ledgerPage.selectKind(LedgerEventKind(.attemptFailed(summary: "filter payload")))
        await model.ledgerPage.showOlder()
        Self.expectPage(model, all: all, matching: matching, limit: 400)

        for count in [0, 1, 7, 201] {
            let appended = try await ledger.append(
                (0..<count).map { Self.event(.attemptFailed(summary: "live failure \(count)-\($0)")) }
                    + [
                        Self.event(.attemptsReset),
                        Self.event(.attemptFailed(summary: "other ticket"), node: "other"),
                        Self.event(.attemptFailed(summary: "descendant"), node: "\(Self.node)/child"),
                        Self.event(.attemptFailed(summary: "no ticket"), node: nil),
                    ])
            all += appended
            matching += appended.prefix(count)
            await session.refresh()
            #expect(model.ledgerPage.limit == 400)
            Self.expectPage(model, all: all, matching: matching, limit: 400)
            await session.refresh()
            #expect(model.ledgerPage.limit == 400)
            Self.expectPage(model, all: all, matching: matching, limit: 400)
        }
        await model.ledgerPage.showOlder()
        await model.ledgerPage.showOlder()
        Self.expectPage(model, all: all, matching: matching, limit: 800)
        #expect(model.ledgerPage.records.count == matching.count)
    }

    @Test(arguments: ["reset", "restart", "restore"])
    func replacingTheLedgerInvalidatesPagesEvenWhenPositionsAndCountsOverlap(operation: String) async throws {
        let store = InMemoryLedgerStore()
        let original = try Ledger(store: store)
        let originalRecords = try await original.append(Self.events(count: 410))
        let model = HarnessViewModel()
        let session = HarnessLedgerSession(view: model, source: original)
        await session.refresh()
        await model.ledgerPage.showOlder()
        let replacement: Ledger
        let replacementRecords: [RecordedEvent]
        if operation == "restart" {
            replacement = try Ledger(store: store)
            replacementRecords = originalRecords
        } else {
            replacement = try Ledger()
            replacementRecords = try await replacement.append(
                Self.events(count: operation == "reset" ? 0 : 410, node: "replacement-node"))
        }
        #expect(replacement.ledgerID != original.ledgerID)
        switch operation {
        case "reset": await session.reset(to: replacement)
        case "restart": await session.restart(from: replacement)
        default: await session.restore(from: replacement)
        }
        Self.expectPage(model, all: replacementRecords, matching: replacementRecords,
                        limit: model.ledgerPage.limit)
        #expect(model.records.map(\.event.id) == replacementRecords.map(\.event.id))
        #expect(Set(model.ledgerPage.nodeIDs) == Set(replacementRecords.compactMap(\.event.node)))
        let tail = try await replacement.append([Self.event(.attemptFailed(summary: operation), node: nil)])
        await session.refresh()
        Self.expectPage(model, all: replacementRecords + tail, matching: replacementRecords + tail,
                        limit: model.ledgerPage.limit)
        #expect(model.ledgerPage.records.first?.event.id == tail.first?.event.id)
        #expect(model.records.map(\.event.id) == (replacementRecords + tail).map(\.event.id))
    }

    @Test
    func anInFlightOldSnapshotCannotOverwriteAReplacementLedger() async throws {
        let original = try Ledger()
        try await original.append(Self.events(count: 211))
        let held = GH69HeldPageSource(ledger: original)
        let model = HarnessViewModel()
        let session = HarnessLedgerSession(view: model, source: held)
        let oldRefresh = Task { await session.refresh() }
        defer { held.release() }
        try await held.waitUntilRequested()

        let replacement = try Ledger()
        var records = try await replacement.append(Self.events(count: 5, node: "replacement"))
        await session.restore(from: replacement)
        held.release()
        await oldRefresh.value
        Self.expectPage(model, all: records, matching: records, limit: model.ledgerPage.limit)
        #expect(model.records.map(\.event.id) == records.map(\.event.id))
        #expect(model.ledgerPage.nodeIDs == ["replacement"])
        records += try await replacement.append(Self.events(count: 1, node: "replacement"))
        await session.refresh()
        Self.expectPage(model, all: records, matching: records, limit: model.ledgerPage.limit)
        #expect(model.records(for: "replacement").map(\.event.id) == records.map(\.event.id))
    }

    @Test
    func pageRefreshUsesOnlyBoundedSnapshotsAndDoesNotReplaceLegacyHistory() async throws {
        let ledger = try Ledger()
        let initial = try await ledger.append(Self.events(count: 1_205))
        let source = PageProbe(ledger: ledger)
        let model = HarnessViewModel()
        await model.refreshHistory(from: ledger)
        await model.refreshLedger(from: source)
        let tail = try await ledger.append(Self.events(count: 7))
        await model.refreshLedger(from: source)
        #expect(model.records.map(\.event.id) == initial.map(\.event.id))
        Self.expectPage(model, all: initial + tail, matching: initial + tail, limit: 200)
        await model.ledgerPage.showOlder()
        let requests = await source.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.returned <= $0.limit })
        #expect(requests.allSatisfy { $0.limit == 200 || $0.limit == 400 })
        #expect(requests.last?.returned == 400)
        #expect(await source.historyRecordsTransferred == 0)
        await model.refreshHistory(from: ledger)
        #expect(model.records.map(\.event.id) == (initial + tail).map(\.event.id))
        #expect(model.records(for: Self.node).map(\.event.id) == (initial + tail).map(\.event.id))
        #expect(model.ledgerPage.records.count == 400)
    }

    @Test
    func sharedAppRefreshBridgeKeepsPagesBoundedAndUpdatesCompleteIndexedHistory() async throws {
        let ledger = try Ledger()
        let spec = NodeSpec(id: Self.node, parent: nil, kind: .leaf, title: "Refresh integration",
                            intent: "Refresh both app modes", acceptanceCriteria: ["Keep complete history"])
        var all = try await ledger.append(
            [Self.event(.nodeCreated(spec: spec, ticket: "GH-69"))] + Self.events(count: 1_204))
        let source = PageProbe(ledger: ledger)
        let model = HarnessViewModel()
        let session = HarnessLedgerSession(view: model, source: source)
        await session.refresh()
        Self.expectPage(model, all: all, matching: all, limit: 200)
        #expect(model.state.nodes[Self.node]?.displayName == "GH-69")
        await model.ledgerPage.showOlder()
        for count in [1, 7, 201] {
            all += try await ledger.append(Self.events(count: count))
            let beforeAppendRefresh = await source.historyRecordsTransferred
            await session.refresh()
            #expect(await source.historyRecordsTransferred - beforeAppendRefresh <= 400 + count)
            let beforeUnchangedRefresh = await source.historyRecordsTransferred
            await session.refresh()
            #expect(await source.historyRecordsTransferred - beforeUnchangedRefresh <= 400)
            Self.expectPage(model, all: all, matching: all, limit: 400)
            #expect(model.records.map(\.event.id) == all.map(\.event.id))
            #expect(model.records(for: Self.node).map(\.event.id) == all.map(\.event.id))
        }
        let requests = await source.requests
        #expect(requests.contains { $0.limit == 200 && $0.returned == 200 })
        #expect(requests.contains { $0.limit == 400 && $0.returned == 400 })
        #expect(requests.allSatisfy { ($0.limit == 200 || $0.limit == 400) && $0.returned <= $0.limit })
        #expect(await source.stateRequests > 1)
    }

    @Test
    func agentRunHistoryRemainsCompleteOutsideTheDisplayedPageAndFilters() async throws {
        let ledger = try Ledger()
        let history = try await ledger.append([
            Self.event(.runStarted(run: "old-author", role: .testAuthor)),
            Self.event(.runFinished(run: "old-author", outcome: "tests committed")),
            Self.event(.runStarted(run: "old-builder", role: .implementer)),
            Self.event(.runFinished(run: "old-builder", outcome: "submitted")),
        ] + Self.events(count: 520, node: "other"))
        let model = HarnessViewModel()
        let session = HarnessLedgerSession(view: model, source: ledger)
        await session.refresh()
        #expect(model.ledgerPage.records.allSatisfy { $0.event.node == "other" })
        await model.ledgerPage.selectNode("other")
        await model.ledgerPage.selectKind(LedgerEventKind(.attemptsReset))
        let runs = AgentRuns.runs(of: Self.node, in: model)
        #expect(runs.map(\.run) == ["old-author", "old-builder"])
        #expect(runs.map(\.outcome) == ["tests committed", "submitted"])
        #expect(model.records.map(\.event.id) == history.map(\.event.id))
        #expect(model.records(for: Self.node).map(\.event.id) == Array(history.prefix(4)).map(\.event.id))
        #expect(AgentRuns.runs(of: Self.node, in: model.ledgerPage.records).isEmpty)
        await model.ledgerPage.showOlder()
        #expect(AgentRuns.runs(of: Self.node, in: model).map(\.run) == runs.map(\.run))
    }

    @Test
    func bitmapRendererCanReadIndependentSwiftUIText() throws {
        let text = try Self.visibleText(Text("Independent ledger renderer probe").font(.title))
        #expect(RenderedUI.shows("Independent ledger renderer probe", in: text))
    }

    @Test
    func pagingUIHelpersActivateStandardSwiftUIControlsAndRevealAnOffscreenListRow() async throws {
        let (presses, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        let probe = GH69ControlProbe()
        let controls = VStack {
            Button("Show older") { signal.yield(()) }
            Picker("Ticket", selection: Binding(get: { probe.ticket }, set: { probe.ticket = $0 })) {
                Text("All tickets").tag("All tickets")
                Text("GH-69").tag("GH-69")
            }.pickerStyle(.menu)
            List(0..<400, id: \.self) { index in
                Text("Independent paging row \(index)")
            }
        }
        let hosted = Self.host(controls, interactive: true)
        defer { hosted.window.close() }
        let reference = Self.host(controls)
        defer { reference.window.close() }
        #expect(try Self.imagePixels(hosted.view) == Self.imagePixels(reference.view),
                "The action bridge must preserve standard SwiftUI control rendering")
        try Self.press("Show older", in: hosted.view)
        DispatchQueue.global().asyncAfter(deadline: .now() + HangGuard.seconds) { signal.finish() }
        var pressed = false
        for await _ in presses { pressed = true; break }
        #expect(pressed)
        try Self.select("GH-69", filter: "All tickets", in: hosted.view)
        try await Self.waitForPage(HarnessViewModel()) { probe.ticket == "GH-69" }
        #expect(RenderedUI.shows("GH-69", in: try Self.visibleText(hosted.view)))
        try Self.select("All tickets", filter: "All tickets", in: hosted.view)
        try await Self.waitForPage(HarnessViewModel()) { probe.ticket == "All tickets" }
        try Self.scrollToLastLedgerRow(in: hosted.view, count: 400)
        #expect(RenderedUI.shows("Independent paging row 399", in: try Self.visibleText(hosted.view)))
    }

    @Test
    func ledgerPaneShowsPagedRecordsAndExactHeaderInsteadOfLegacyRows() async throws {
        let ledger = try Ledger()
        let spec = NodeSpec(id: Self.node, parent: nil, kind: .leaf, title: "Ledger pane",
                            intent: "Show matching records", acceptanceCriteria: ["Retain row details"])
        let all = try await ledger.append([
            Self.event(.nodeCreated(spec: spec, ticket: "GH-69"), node: spec.id),
        ] + Self.events(count: 731, node: "other") + [
            LedgerEvent(node: spec.id, by: .human("Ledger Reviewer"),
                        kind: .attemptFailed(summary: "Visible filtered failure")),
        ])
        let model = HarnessViewModel()
        model.state = await ledger.workingState()
        let legacy = try Ledger()
        let legacyRecords = try await legacy.append([
            Self.event(.attemptFailed(summary: "Stale legacy sentinel")),
        ])
        let session = HarnessLedgerSession(view: model, source: ledger)
        await session.refresh()
        model.records = legacyRecords
        let hosted = Self.host(LedgerPane().environment(model), interactive: true)
        defer { hosted.window.close() }
        let initialText = try Self.visibleText(hosted.view)
        #expect(RenderedUI.shows("733 records", in: initialText))
        #expect(RenderedUI.shows("All tickets", in: initialText))
        #expect(RenderedUI.shows("All event kinds", in: initialText))
        #expect(RenderedUI.shows("Show older", in: initialText))
        #expect(!RenderedUI.shows("Stale legacy sentinel", in: initialText))

        let tickets = try #require(Self.descendants(hosted.view, as: NSPopUpButton.self)
            .first { $0.itemTitles.contains("All tickets") })
        let kinds = try #require(Self.descendants(hosted.view, as: NSPopUpButton.self)
            .first { $0.itemTitles.contains("All event kinds") })
        #expect(Set(tickets.itemTitles) == Set(["All tickets", "GH-69", "other"]))
        #expect(tickets.itemTitles.count == 3)
        #expect(Set(kinds.itemTitles) == Set(["All event kinds"] + Self.existingEventCaseNames))
        #expect(kinds.itemTitles.count == Self.existingEventCaseNames.count + 1)
        #expect(tickets.itemArray.allSatisfy { $0.isEnabled })
        #expect(kinds.itemArray.allSatisfy { $0.isEnabled })
        #expect(model.ledgerPage.canShowOlder)
        #expect(model.ledgerPage.limit == 200)
        #expect(!model.ledgerPage.records.contains { $0.event.id == all[333].event.id })
        try Self.press("Show older", in: hosted.view)
        try await Self.waitForPage(model) { model.ledgerPage.limit == 400 && model.ledgerPage.records.count == 400 }
        Self.expectPage(model, all: all, matching: all, limit: 400)
        try Self.scrollToLastLedgerRow(in: hosted.view, count: 400)
        #expect(Self.showsRow(all[333], in: try Self.visibleText(hosted.view)))
        try Self.select("GH-69", filter: "All tickets", in: hosted.view)
        try await Self.waitForPage(model) {
            model.ledgerPage.limit == 200 && model.ledgerPage.records.map(\.event.id) == [all[732].event.id, all[0].event.id]
        }
        try Self.select("attemptFailed", filter: "All event kinds", in: hosted.view)
        try await Self.waitForPage(model) { model.ledgerPage.records.map(\.event.id) == [all[732].event.id] }
        let filteredText = try Self.visibleText(hosted.view)
        let last = try #require(all.last)
        #expect(RenderedUI.shows("733 records", in: filteredText))
        #expect(RenderedUI.shows("Visible filtered failure", in: filteredText))
        #expect(RenderedUI.shows("Ledger Reviewer", in: filteredText))
        #expect(RenderedUI.shows(NodeIdentity(ticketKey: "GH-69", nodeID: spec.id).displayName, in: filteredText))
        #expect(RenderedUI.shows("#\(last.position)", in: filteredText))
        #expect(RenderedUI.shows(String(last.hash.prefix(10)), in: filteredText))
        #expect(!RenderedUI.shows("Show older", in: filteredText))
        try Self.select("other", filter: "All tickets", in: hosted.view)
        try await Self.waitForPage(model) { model.ledgerPage.records.isEmpty }
        let emptyText = try Self.visibleText(hosted.view)
        #expect(RenderedUI.shows("733 records", in: emptyText))
        #expect(!RenderedUI.shows("Visible filtered failure", in: emptyText))
        #expect(!RenderedUI.shows("Stale legacy sentinel", in: emptyText))
        try Self.select("All event kinds", filter: "All event kinds", in: hosted.view)
        try await Self.waitForPage(model) { model.ledgerPage.records.count == 200 }
        hosted.view.layoutSubtreeIfNeeded()
        #expect(RenderedUI.shows("Show older", in: try Self.visibleText(hosted.view)))
        #expect(model.ledgerPage.canShowOlder)
        #expect(model.ledgerPage.limit == 200)
        #expect(!model.ledgerPage.records.contains { $0.event.id == all[332].event.id })
        try Self.press("Show older", in: hosted.view)
        try await Self.waitForPage(model) { model.ledgerPage.limit == 400 && model.ledgerPage.records.count == 400 }
        Self.expectPage(model, all: all, matching: all.filter { $0.event.node == "other" }, limit: 400)
        try Self.scrollToLastLedgerRow(in: hosted.view, count: 400)
        #expect(Self.showsRow(all[332], in: try Self.visibleText(hosted.view)))
        try Self.select("All tickets", filter: "All tickets", in: hosted.view)
        try await Self.waitForPage(model) {
            model.ledgerPage.limit == 200 && model.ledgerPage.records.first?.event.id == last.event.id
        }
        Self.expectPage(model, all: all, matching: all, limit: 200)
    }

    private static let node: NodeID = "wn-GH-69"

    @Observable private final class GH69ControlProbe {
        var ticket = "All tickets"
    }

    private static func event(_ kind: EventKind, node: NodeID? = Self.node) -> LedgerEvent {
        let participant: Participant
        switch kind {
        case .gateOpened:
            participant = .human("Ledger fixture")
        case .evidenceRecorded(let evidence), .landingReworkNeeded(let evidence):
            participant = .agent(run: evidence.checkedBy, role: .verifier)
        default:
            participant = .reconciler
        }
        return LedgerEvent(node: node, by: participant, kind: kind)
    }

    private static func events(count: Int, node: NodeID? = Self.node) -> [LedgerEvent] {
        (0..<count).map { index in
            LedgerEvent(node: node, by: .adapter("ledger fixture"), kind: .attemptsReset,
                        at: Date(timeIntervalSince1970: Double(count - index)))
        }
    }

    private static func expectPage(_ model: HarnessViewModel, all: [RecordedEvent],
                                   matching: [RecordedEvent], limit: Int) {
        let expected = Array(matching.suffix(limit).reversed())
        #expect(model.ledgerPage.totalCount == all.count)
        #expect(model.ledgerPage.matchingCount == matching.count)
        #expect(model.ledgerPage.records.map(\.event.id) == expected.map(\.event.id))
        #expect(model.ledgerPage.records.map(\.position) == expected.map(\.position))
        #expect(model.ledgerPage.records.map(\.hash) == expected.map(\.hash))
        #expect(Set(model.ledgerPage.records.map(\.event.id)).count == model.ledgerPage.records.count)
        #expect(model.ledgerPage.canShowOlder == (matching.count > expected.count))
    }

    private actor PageProbe: HarnessLedgerRefreshSource {
        struct Request: Sendable {
            let limit: Int
            let returned: Int
        }
        let ledger: Ledger
        private(set) var requests: [Request] = []
        private(set) var historyRecordsTransferred = 0
        private(set) var stateRequests = 0

        init(ledger: Ledger) { self.ledger = ledger }
        var ledgerID: UUID { get async { await ledger.ledgerID } }

        func historySnapshot() async -> LedgerHistorySnapshot {
            let snapshot = await ledger.historySnapshot()
            historyRecordsTransferred += snapshot.records.count
            return snapshot
        }

        func records(after position: Int, limit: Int) async -> [RecordedEvent] {
            let records = await ledger.records(after: position, limit: limit)
            historyRecordsTransferred += records.count
            #expect(records.count <= limit)
            #expect(records.allSatisfy { $0.position > position })
            return records
        }

        func workingState() async -> WorkingState {
            stateRequests += 1
            return await ledger.workingState()
        }

        func pageSnapshot(node: NodeID?, kind: LedgerEventKind?, limit: Int) async -> LedgerPageSnapshot {
            let snapshot = await ledger.pageSnapshot(node: node, kind: kind, limit: limit)
            requests.append(Request(limit: limit, returned: snapshot.records.count))
            return snapshot
        }
    }

    private static func visibleText<Content: View>(_ content: Content) throws -> String {
        try RenderedUI.text(of: content, size: CGSize(width: 1_100, height: 850))
    }

    /// Whether the record's row is rendered. OCR sometimes misses the short "#position" label of the row at the
    /// list's edge, so its hash, also unique to the row, counts too.
    private static func showsRow(_ record: RecordedEvent, in text: String) -> Bool {
        RenderedUI.shows("#\(record.position)", in: text) || RenderedUI.shows(String(record.hash.prefix(10)), in: text)
    }

    private static func visibleText(_ view: NSView) throws -> String {
        try RenderedUI.text(in: RenderedUI.image(of: view)).joined(separator: "\n")
    }

    static let existingEventCaseNames = [
        "signalAccepted", "signalRejected", "previewRecorded", "previewStarted", "previewFinished", "breakdownChecked", "breakdownRetryRequested",
        "nodeCreated", "linkAdded", "becameLeaf", "replanned", "breakdownRevised", "gateOpened",
        "phaseChanged", "flagSet", "flagCleared", "attemptsReset", "testsFixed", "otherTestsUpdated", "reviewRecorded",
        "humanReviewRequested", "humanReviewApproved", "expectedAPIReported", "brokenTestReported",
        "brokenTestRouted", "runStarted", "runFinished", "changeSubmitted", "attemptFailed",
        "acceptanceTestPreflightFailed", "passingCheckRecorded", "mainMovedRework", "evidenceRecorded",
        "landingReworkNeeded", "landingRerunRequested", "reworkNeeded", "landed", "questionsRaised",
        "assumptionsReported", "suggestionsReported", "questionsAnswered", "externalDependencyResolved",
        "ticketClosed", "ticketReopened", "readinessScanned", "baselineChecked", "catchUpConflicted",
        "catchUpSucceeded", "caughtUp", "testDraftKept", "diagnosisRecorded",
        "agentConfigured", "overlapHoldStarted", "overlapHoldEnded",
        "actualChangedFilesRecorded", "predictedPathsExpanded", "requirementBranchCreated",
        "requirementBranchObserved", "requirementCatchUpConflicted",
    ]
}
