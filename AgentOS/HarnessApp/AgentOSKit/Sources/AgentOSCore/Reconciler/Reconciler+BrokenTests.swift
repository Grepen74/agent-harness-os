import Foundation

extension Reconciler {
    /// Whether the node waits because a test of other work conflicts with it: the latest "Needs input" came with
    /// a broken-test report (same run, nothing started in between) naming a test that isn't the node's own.
    func isWaitingOnOtherTest(_ node: NodeState) async -> Bool {
        guard node.flags[.needsInput] != nil else { return false }
        let records = await ledger.records(for: node.id)
        guard let flag = records.last(where: {
            if case .flagSet(.needsInput, _) = $0.event.kind { return true }
            return false
        }) else { return false }
        for record in records.reversed() where record.position < flag.position {
            switch record.event.kind {
            case .brokenTestReported(let report): return !isOwnTest(report.testName, of: node)
            case .runStarted: return false
            default: continue
            }
        }
        return false
    }

    func routeBrokenTest(
        _ report: BrokenTestReport,
        from node: NodeState,
        run: RunID,
        author: Participant,
        directory: URL
    ) async throws -> String {
        try await workspace.resetForRework(directory)
        let finished = EventKind.runFinished(run: run, outcome: "reported a broken test: \(report.testName)")

        let earlier = await brokenReportsSentBackSincePersonSteppedIn(node.id)
        let isOther = !isOwnTest(report.testName, of: node)
        guard earlier.count < Self.automaticTestReturns else {
            let history = (earlier.map { "Earlier: \($0.testName): \($0.reason)" }
                + ["Now: \(report.testName): \(report.reason)"]).joined(separator: "\n")
            let reason = isOther ? """
                \(report.testName) isn't one of this ticket's acceptance tests. Its expectations conflict with this \
                ticket, and the test author couldn't settle it in \(earlier.count) tries (it may only update another \
                item's test where this ticket's criteria deliberately change what that test checks):
                \(history)
                Next: if that test is out of date, change it on the default branch and commit; once the harness has \
                caught up, add harness:retry. Otherwise comment how to proceed, then add harness:retry.
                """ : """
                The test author already reworked these tests \(earlier.count) times after broken-test reports:
                \(history)
                Next: review the reports, comment with guidance, then add harness:retry. To have the tests written \
                again from scratch, add harness:retest instead.
                """
            try await write(node.id, by: author, [
                finished,
                .brokenTestReported(report),
                .brokenTestRouted(testName: report.testName, outcome: isOther ? .otherTestWaitingForPerson : .waitingForPerson),
                .phaseChanged(to: .ready),
                .flagSet(.needsInput, reason: reason),
            ])
            await tracker.comment(on: node.ticket, isOther
                ? "\(Self.needsInputMarker): another test conflicts with this ticket.\n\(reason)"
                : """
                \(Self.needsInputMarker): broken acceptance test \(report.testName): \(report.reason)
                waiting for a person: the test author already reworked these tests.
                \(reason)
                """)
            return isOther
                ? "\(node.ticket) conflicts with \(report.testName) → waiting for a person"
                : "\(node.displayName) broken test \(report.testName) → waiting for a person"
        }

        try await write(node.id, by: author, [
            finished,
            .brokenTestReported(report),
            .brokenTestRouted(testName: report.testName, outcome: .sentBackToTestAuthor),
            .phaseChanged(to: .specified),
        ])
        let otherNote = isOther
            ? "\nIt isn't one of this ticket's tests: the test author may update it only where this ticket's criteria "
                + "deliberately change what it checks."
            : ""
        await tracker.comment(on: node.ticket, """
            🔁 Broken acceptance test \(report.testName): \(report.reason)
            sent back to the test author.\(otherNote)
            """)
        return "\(node.displayName) broken test \(report.testName) → sent back to the test author"
    }

    /// Whether a reported test may belong to this node. Only a name that clearly points at another suite
    /// (`FlowTests.someTest`, or a path outside the node's test folder) counts as other work.
    private func isOwnTest(_ testName: String, of node: NodeState) -> Bool {
        let folder = workspace.testFolder(for: node.spec)
        let suite = folder.split(separator: "/").last.map(String.init) ?? folder
        if testName.contains("/") { return testName.contains(folder) }
        guard let leading = testName.split(separator: ".").first.map(String.init), leading != testName,
              leading.hasSuffix("Tests") else { return true }
        return leading == suite
    }

    /// How often broken-test reports go back to the test author before a person is asked: one rewrite can fix a
    /// test and still leave another one broken, so the second try is worth more than a person's wait.
    static let automaticTestReturns = 2

    /// The broken-test reports sent back to the test author since a person last stepped in (an answer, a retry,
    /// a retest), oldest first.
    private func brokenReportsSentBackSincePersonSteppedIn(_ id: NodeID) async -> [BrokenTestReport] {
        let records = await ledger.records(for: id)
        let steppedIn = records.lastIndex {
            guard case .human = $0.event.by else { return false }
            switch $0.event.kind {
            case .questionsAnswered, .attemptsReset:
                return true
            case .signalAccepted(_, let command, _):
                return command == .retry || command == .retest
            default:
                return false
            }
        }
        var reports: [BrokenTestReport] = []
        var latest: BrokenTestReport?
        for record in records[(steppedIn.map { $0 + 1 } ?? 0)...] {
            switch record.event.kind {
            case .brokenTestReported(let report): latest = report
            case .brokenTestRouted(_, .sentBackToTestAuthor): if let latest { reports.append(latest) }
            default: continue
            }
        }
        return reports
    }
}
