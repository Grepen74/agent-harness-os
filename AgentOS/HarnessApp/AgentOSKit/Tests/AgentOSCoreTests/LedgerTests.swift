import Foundation
import Testing
@testable import AgentOSCore

let alice = Participant.human("Alice")

@Suite("Ledger")
struct LedgerTests {
    let spec = NodeSpec(id: "wn-1", parent: nil, kind: .leaf, title: "T", intent: "I", acceptanceCriteria: ["a"])

    @Test func readinessScanIsRecordedOnlyWhenItChanges() async throws {
        let ledger = try Ledger()
        let scan = ReadinessScan(branch: "main", commit: "a", findings: [Finding(check: "x", severity: .warning, title: "No README")])
        #expect(try await ledger.record(scan))
        #expect(try await !ledger.record(scan))
        #expect(try await ledger.record(ReadinessScan(branch: "main", commit: "b", findings: scan.findings)))
        #expect(await ledger.allRecords().count == 2)
        #expect(await ledger.workingState().readiness?.commit == "b")
    }

    @Test func retriedEventsAreRecordedOnce() async throws {
        let ledger = try Ledger()
        let event = LedgerEvent(node: spec.id, by: alice, kind: .nodeCreated(spec: spec, ticket: "APP-1"))
        try await ledger.append([event])
        try await ledger.append([event])
        #expect(await ledger.allRecords().count == 1)
    }

    @Test func refusesWritesBasedOnStaleState() async throws {
        let ledger = try Ledger()
        try await ledger.append([LedgerEvent(node: spec.id, by: alice, kind: .nodeCreated(spec: spec, ticket: "APP-1"))])
        let seen = await ledger.workingState().nodes[spec.id]!.version
        try await ledger.append([LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .ready))])

        await #expect(throws: LedgerError.self) {
            try await ledger.append([LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .building))],
                                    expecting: [spec.id: seen])
        }
    }

    @Test func builderCannotCheckOwnWork() async throws {
        let ledger = try Ledger()
        let evidence = Evidence(check: "swift test", passed: true, summary: "ok", specHash: "x", builtBy: "run-1",
                                checkedBy: "run-1", artifactPath: "", artifactSHA256: "", commit: "abc123")
        await #expect(throws: LedgerError.self) {
            try await ledger.append([LedgerEvent(node: spec.id, by: .agent(run: "run-1", role: .verifier), kind: .evidenceRecorded(evidence))])
        }
    }

    @Test func reviewsAndEvidenceShowWhenTheLedgerRecordedThemWithoutStoringItInTheEvent() async throws {
        let ledger = try Ledger()
        let reviewedAt = Date(timeIntervalSince1970: 1_000), checkedAt = Date(timeIntervalSince1970: 2_000)
        let review = ReviewRecord(stage: .change, result: ReviewResult(passed: true, findings: []), commit: "abc123", uiEvidence: nil)
        let evidence = Evidence(check: "swift test", passed: true, summary: "ok", specHash: "x", builtBy: "run-1",
                                checkedBy: "run-2", artifactPath: "", artifactSHA256: "", commit: "abc123")
        try await ledger.append([
            LedgerEvent(node: spec.id, by: alice, kind: .nodeCreated(spec: spec, ticket: "APP-1")),
            LedgerEvent(node: spec.id, by: .reconciler, kind: .reviewRecorded(review), at: reviewedAt),
            LedgerEvent(node: spec.id, by: .agent(run: "run-2", role: .verifier), kind: .evidenceRecorded(evidence), at: checkedAt),
        ])

        let node = try #require(await ledger.workingState().nodes[spec.id])
        #expect(node.reviews.map(\.recordedAt) == [reviewedAt])
        #expect(node.evidence.map(\.recordedAt) == [checkedAt])
        let recorded = String(decoding: try JSONEncoder().encode(await ledger.allRecords().map(\.event)), as: UTF8.self)
        #expect(!recorded.contains("recordedAt"))
    }

    @Test func onlyHumansOpenGates() async throws {
        let ledger = try Ledger()
        await #expect(throws: LedgerError.self) {
            try await ledger.append([LedgerEvent(node: spec.id, by: .reconciler, kind: .gateOpened(.build))])
        }
    }

    @Test func reviewFindingsStillStandAfterTheImplementerRunForThemFails() async throws {
        let ledger = try Ledger()
        let findings = ReviewRecord(stage: .change, result: ReviewResult(passed: false, findings: ["refresh() races"]),
                                    commit: "abc123", uiEvidence: nil)
        try await ledger.append([
            LedgerEvent(node: spec.id, by: alice, kind: .nodeCreated(spec: spec, ticket: "APP-1")),
            LedgerEvent(node: spec.id, by: .agent(run: "run-2", role: .verifier), kind: .reviewRecorded(findings)),
            LedgerEvent(node: spec.id, by: .agent(run: "run-3", role: .implementer),
                        kind: .attemptFailed(summary: "copilot timed out after 2400.0 seconds")),
        ])
        let node = try #require(await ledger.workingState().nodes[spec.id])
        #expect(node.latestReviewFeedback == "refresh() races")
        #expect(!node.reviewFeedbackAnswered)
    }
}
