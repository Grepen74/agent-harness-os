// Expected API: Ledger.verifyIncrementally() -> ChainReport and Ledger.records(for: NodeID) -> [RecordedEvent],
// both actor-isolated, backed by FileLedgerStore; existing append and verifyChain APIs remain unchanged.
//
// Opt in from the repository root:
// cd AgentOS/HarnessApp && xcodegen generate
// cd AgentOSKit && AGENTOS_RUN_GH70_BENCHMARK=1 swift test -c release --filter GH_70Tests
//
// Metrics use ContinuousClock wall time, including actor hops and verified-prefix digest checking.
// Each median is the mean of sorted samples 10 and 11 from 20 measurements after one warm-up.
// Unchanged: verifyIncrementally on a checkpointed 20,000-record file, without writes.
// Appended: verifyIncrementally after exactly one legitimate append to an independently prepared checkpoint.
// Lookup: records(for:) returning all 200 original records of node 42, without appending to that node.
// Fixture creation, opening, full verification, checkpoint preparation, append, validation, and
// reporting are outside these intervals. Full verifyChain wall time is reported separately.
// Ordinary tests never impose performance thresholds. The opt-in benchmark requires release mode.

import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

@Suite(.serialized, .timeLimit(.minutes(10)))
struct GH_70Tests {
    private static let recordCount = 20_000
    private static let nodeCount = 100
    private static let selectedNode: NodeID = "gh70-node-42"
    private static let optedIn =
        ProcessInfo.processInfo.environment["AGENTOS_RUN_GH70_BENCHMARK"] == "1"

    @Test("AC1: deterministic disk fixtures contain 20,000 valid records across 100 nodes")
    func deterministicFileFixtureHasTheRequiredDistribution() async throws {
        try await withDirectory { directory in
            let first = try await makeFixture(at: directory.appending(path: "first.jsonl"))
            let second = try await makeFixture(at: directory.appending(path: "second.jsonl"))
            let stored = try FileLedgerStore(fileURL: first.fileURL).loadAll()
            let repeated = try FileLedgerStore(fileURL: second.fileURL).loadAll()
            #expect(stored.map(\.hash) == repeated.map(\.hash))
            #expect(stored.map(\.event.id) == repeated.map(\.event.id))
            #expect(stored.map(\.event.at) == repeated.map(\.event.at))
            #expect(stored.count == Self.recordCount)
            #expect(Set(stored.compactMap(\.event.node)).count == Self.nodeCount)
            for index in 0..<Self.nodeCount {
                #expect(stored.filter { $0.event.node == Self.node(index) }.count == 200)
            }
            try requireIntact(await first.ledger.verifyChain(), count: Self.recordCount)
            try requireOriginalLookup(await first.ledger.records(for: Self.selectedNode), fixture: first)
        }
    }

    @Test("AC2-4: opt-in release medians and full-chain reference include validated results",
          .enabled(if: Self.optedIn))
    func releaseFileLedgerBenchmark() async throws {
        #if DEBUG
        Issue.record("Use the documented -c release invocation; debug timings are not benchmark results.")
        return
        #else
        try await withDirectory { directory in
            let fixture = try await makeFixture(at: directory.appending(path: "base.jsonl"))
            let bytes = try Data(contentsOf: fixture.fileURL)
            let expected = fixture.originalSelected

            // Warm-up results are consumed just like measured results.
            try requireIntact(await fixture.ledger.verifyIncrementally())
            try requireOriginalLookup(await fixture.ledger.records(for: Self.selectedNode), fixture: fixture)
            var unchanged: [Double] = []
            var lookup: [Double] = []
            for _ in 0..<20 {
                let check = await measure { await fixture.ledger.verifyIncrementally() }
                try requireIntact(check.value)
                unchanged.append(check.milliseconds)
                let records = await measure { await fixture.ledger.records(for: Self.selectedNode) }
                try requireOriginalLookup(records.value, fixture: fixture)
                lookup.append(records.milliseconds)
            }

            var appended: [Double] = []
            for sample in 0...20 {
                let url = directory.appending(path: "append-\(sample).jsonl")
                try bytes.write(to: url)
                let ledger = try Ledger(store: FileLedgerStore(fileURL: url))
                try requireIntact(await ledger.verifyChain(), count: Self.recordCount)
                try requireIntact(await ledger.verifyIncrementally())
                let addition = try await ledger.append([Self.appendEvent])
                try #require(addition.count == 1)
                try #require(addition[0].position == Self.recordCount)
                let check = await measure { await ledger.verifyIncrementally() }
                try requireIntact(check.value)
                let history = await ledger.records(for: Self.selectedNode)
                try #require(history.map(\.hash) == expected.map(\.hash))
                if sample > 0 { appended.append(check.milliseconds) }
                try FileManager.default.removeItem(at: url)
            }

            let full = await measure { await fixture.ledger.verifyChain() }
            try requireIntact(full.value, count: Self.recordCount)
            let machine = try await ProcessRunner.run(
                "/usr/sbin/sysctl", ["-n", "hw.model"], in: directory, timeout: .seconds(30))
            let architecture = try await ProcessRunner.run(
                "/usr/bin/uname", ["-m"], in: directory, timeout: .seconds(30))
            let swift = try await ProcessRunner.run(
                "/usr/bin/xcrun", ["swift", "--version"], in: directory, timeout: .seconds(30))
            try #require(machine.status == 0 && architecture.status == 0 && swift.status == 0)
            try #require(!machine.output.isEmpty && !architecture.output.isEmpty && !swift.output.isEmpty)
            let unchangedMedian = try median(unchanged)
            let appendedMedian = try median(appended)
            let lookupMedian = try median(lookup)
            print("""
            GH-70 file-backed ledger benchmark
            records=\(Self.recordCount), nodes=\(Self.nodeCount), bytes=\(bytes.count)
            machine=\(machine.output.trimmingCharacters(in: .whitespacesAndNewlines))
            architecture=\(architecture.output.trimmingCharacters(in: .whitespacesAndNewlines))
            OS=\(ProcessInfo.processInfo.operatingSystemVersionString)
            Swift=\(swift.output.trimmingCharacters(in: .whitespacesAndNewlines))
            configuration=release, samples=20, warmups=1, units=ms
            unchanged_quick_check_median=\(unchangedMedian)
            after_one_append_quick_check_median=\(appendedMedian)
            indexed_original_200_records_median=\(lookupMedian)
            full_verify_chain_reference=\(full.milliseconds)
            quick checks include verified-prefix digest checking; setup and validation excluded
            """)
            #expect(unchangedMedian < 20)
            #expect(appendedMedian < 20)
            #expect(lookupMedian < 1)
        }
        #endif
    }

    @Test("AC3: historical tampering is rejected even when modification time is restored",
          arguments: [false, true])
    func quickCheckRejectsHistoricalTamperingWithRestoredModificationTime(afterAppend: Bool) async throws {
        try await withDirectory { directory in
            let fixture = try await makeFixture(at: directory.appending(path: "ledger.jsonl"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                ofItemAtPath: fixture.fileURL.path)
            try requireIntact(await fixture.ledger.verifyIncrementally())
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
            let originalTime = try #require(attributes[.modificationDate] as? Date)
            if afterAppend {
                let appended = try await fixture.ledger.append([Self.appendEvent])
                try #require(appended.count == 1)
            }

            let before = try Data(contentsOf: fixture.fileURL)
            var changed = before
            let range = try #require(changed.range(of: Data("benchmark-original".utf8)))
            changed.replaceSubrange(range, with: Data("benchmark-tampered".utf8))
            try #require(changed.count == before.count)
            // In-place writes preserve the file identity as well as its length.
            let handle = try FileHandle(forWritingTo: fixture.fileURL)
            do {
                try handle.write(contentsOf: changed)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try FileManager.default.setAttributes(
                [.modificationDate: originalTime], ofItemAtPath: fixture.fileURL.path)
            let restored = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
            try #require(restored[.modificationDate] as? Date == originalTime)
            try #require((restored[.size] as? NSNumber)?.intValue == before.count)
            let stored = try FileLedgerStore(fileURL: fixture.fileURL).loadAll()
            try #require(stored.count == Self.recordCount + (afterAppend ? 1 : 0))
            try #require(stored.contains { !$0.isIntact })

            let report = await fixture.ledger.verifyIncrementally()
            #expect(!report.isIntact)
            let problem = try #require(report.problem)
            #expect(!problem.reason.isEmpty)
        }
    }

    @Test("AC4: legitimate appends are consumed and indexed lookup retains the original 200 records")
    func checksAndLookupValidateTheMeasuredWorkload() async throws {
        try await withDirectory { directory in
            let fixture = try await makeFixture(at: directory.appending(path: "ledger.jsonl"))
            try requireIntact(await fixture.ledger.verifyIncrementally())
            let appended = try await fixture.ledger.append([Self.appendEvent])
            try #require(appended.count == 1)
            #expect(appended[0].position == Self.recordCount)
            try requireIntact(await fixture.ledger.verifyIncrementally())
            try requireIntact(await fixture.ledger.verifyIncrementally())
            try requireIntact(await fixture.ledger.verifyChain(), count: Self.recordCount + 1)
            try requireOriginalLookup(await fixture.ledger.records(for: Self.selectedNode), fixture: fixture)
            #expect(await fixture.ledger.records(for: "not-a-fixture-node").isEmpty)
            let appendedNode = await fixture.ledger.records(for: Self.node(0))
            #expect(appendedNode.count == 201)
            #expect(appendedNode.last?.event.id == Self.appendEvent.id)
        }
    }

    @Test("AC5: ordinary correctness checks have no hardware-dependent threshold")
    func ordinaryQuickChecksRemainCorrectWithoutBenchmarkOptIn() async throws {
        try await withDirectory { directory in
            let ledger = try Ledger(store: FileLedgerStore(fileURL: directory.appending(path: "small.jsonl")))
            try await ledger.append([Self.appendEvent])
            try requireIntact(await ledger.verifyChain(), count: 1)
            try requireIntact(await ledger.verifyIncrementally())
            let records = await ledger.records(for: Self.node(0))
            #expect(records.map(\.event.id) == [Self.appendEvent.id])
        }
    }

    @Test("AC6: temporary fixtures are removed on success and on a thrown failure")
    func temporaryFixtureCleanupCoversBothExitPaths() async throws {
        for fail in [false, true] {
            var created: URL?
            do {
                try await withDirectory { directory in
                    created = directory
                    let url = directory.appending(path: "ledger.jsonl")
                    let ledger = try Ledger(store: FileLedgerStore(fileURL: url))
                    try await ledger.append([Self.appendEvent])
                    try #require(FileManager.default.fileExists(atPath: url.path))
                    if fail { throw CleanupProbe.expected }
                }
                #expect(!fail)
            } catch CleanupProbe.expected {
                #expect(fail)
            }
            let directory = try #require(created)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    private struct Fixture {
        let fileURL: URL
        let ledger: Ledger
        let originalSelected: [RecordedEvent]
    }

    private enum CleanupProbe: Error { case expected }

    private static func node(_ index: Int) -> NodeID { "gh70-node-\(index)" }

    private static func eventID(_ position: Int) -> UUID {
        // All callers use nonnegative, bounded fixture positions.
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", position + 1))!
    }

    private static var appendEvent: LedgerEvent {
        LedgerEvent(node: node(0), by: .reconciler, kind: .attemptFailed(summary: "legitimate append"),
                    id: eventID(recordCount), at: Date(timeIntervalSince1970: 1_700_000_000 + Double(recordCount)))
    }

    private func makeFixture(at url: URL) async throws -> Fixture {
        let writer = try Ledger(store: FileLedgerStore(fileURL: url))
        let events = (0..<Self.recordCount).map { position -> LedgerEvent in
            let node = Self.node(position % Self.nodeCount)
            let kind: EventKind
            if position < Self.nodeCount {
                let spec = NodeSpec(id: node, parent: nil, kind: .leaf, title: "Benchmark \(node)",
                                    intent: "Deterministic ledger fixture", acceptanceCriteria: ["Fixture is valid"])
                kind = .nodeCreated(spec: spec, ticket: "BENCH-\(position)")
            } else {
                kind = .attemptFailed(summary: "benchmark-original-\(position)")
            }
            return LedgerEvent(node: node, by: .reconciler, kind: kind, id: Self.eventID(position),
                               at: Date(timeIntervalSince1970: 1_700_000_000 + Double(position)))
        }
        let records = try await writer.append(events)
        try #require(records.count == Self.recordCount)
        let reopened = try Ledger(store: FileLedgerStore(fileURL: url))
        try requireIntact(await reopened.verifyChain(), count: Self.recordCount)
        try requireIntact(await reopened.verifyIncrementally())
        return Fixture(fileURL: url, ledger: reopened,
                       originalSelected: records.filter { $0.event.node == Self.selectedNode })
    }

    private func requireIntact(_ report: ChainReport, count: Int? = nil) throws {
        try #require(report.isIntact, "Integrity failure: \(report.problem?.reason ?? "unknown")")
        if let count { try #require(report.checked == count) }
    }

    private func requireOriginalLookup(_ records: [RecordedEvent], fixture: Fixture) throws {
        try #require(records.count == 200)
        try #require(records.allSatisfy { $0.event.node == Self.selectedNode })
        try #require(records.map(\.event.id) == fixture.originalSelected.map(\.event.id))
        try #require(records.map(\.position) == fixture.originalSelected.map(\.position))
        try #require(records.map(\.hash) == fixture.originalSelected.map(\.hash))
    }

    private func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agentos-gh70-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Failed to clean GH-70 fixture \(directory.path): \(error)") }
        }
        try await body(directory)
    }

    private func measure<T>(_ operation: () async -> T) async -> (value: T, milliseconds: Double) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = await operation()
        let elapsed = start.duration(to: clock.now).components
        return (value, Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
    }

    private func median(_ samples: [Double]) throws -> Double {
        try #require(samples.count == 20)
        try #require(samples.allSatisfy { $0.isFinite && $0 >= 0 })
        let sorted = samples.sorted()
        return (sorted[9] + sorted[10]) / 2
    }
}
