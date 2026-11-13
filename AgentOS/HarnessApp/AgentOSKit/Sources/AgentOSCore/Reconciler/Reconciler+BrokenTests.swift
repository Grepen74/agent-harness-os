import Foundation

extension Reconciler {
    /// Whether the node waits because a test of other work conflicts with it: the latest "Needs input" came with
    /// a broken-test report (same run, nothing started in between) naming a test that isn't the node's own.
    func isWaitingOnOtherTest(_ node: NodeState) async -> Bool {
        guard node.flags[.needsInput] != nil else { return false }
        let records = await ledger.allRecords().filter { $0.event.node == node.id }
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

        // Not one of this ticket's acceptance tests: neither agent may change it, so only a person can decide.
        if !isOwnTest(report.testName, of: node) {
            let reason = """
            \(report.testName) isn't one of this ticket's acceptance tests, so neither the implementer nor the test \
            author may change it. Its expectations conflict with this ticket:
            \(report.reason)
            Next: if that test is out of date, change it on the default branch and commit; once the harness has \
            caught up, add harness:retry. Otherwise comment how to proceed, then add harness:retry.
            """
            try await write(node.id, by: author, [
                finished,
                .brokenTestReported(report),
                .brokenTestRouted(testName: report.testName, outcome: .otherTestWaitingForPerson),
                .phaseChanged(to: .ready),
                .flagSet(.needsInput, reason: reason),
            ])
            await tracker.comment(on: node.ticket, "\(Self.needsInputMarker): another test conflicts with this ticket.\n\(reason)")
            return "\(node.ticket) conflicts with \(report.testName) → waiting for a person"
        }

        if let previous = await brokenReportTheTestsWereAlreadyReworkedFor(node.id) {
            let reason = """
            The test author already reworked these tests after a broken-test report:
            Earlier: \(previous.testName): \(previous.reason)
            Now: \(report.testName): \(report.reason)
            Next: review both reports, comment with guidance, then add harness:retry. To have the tests written \
            again from scratch, add harness:retest instead.
            """
            try await write(node.id, by: author, [
                finished,
                .brokenTestReported(report),
                .brokenTestRouted(testName: report.testName, outcome: .waitingForPerson),
                .phaseChanged(to: .ready),
                .flagSet(.needsInput, reason: reason),
            ])
            await tracker.comment(on: node.ticket, """
                \(Self.needsInputMarker): broken acceptance test \(report.testName): \(report.reason)
                waiting for a person: the test author already reworked these tests.
                \(reason)
                """)
            return "\(node.displayName) broken test \(report.testName) → waiting for a person"
        }

        try await write(node.id, by: author, [
            finished,
            .brokenTestReported(report),
            .brokenTestRouted(testName: report.testName, outcome: .sentBackToTestAuthor),
            .phaseChanged(to: .specified),
        ])
        await tracker.comment(on: node.ticket, """
            🔁 Broken acceptance test \(report.testName): \(report.reason)
            sent back to the test author.
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

    /// The broken-test report the current tests were rewritten for, unless a person stepped in since then
    /// (an answer, a retry, a retest). Nil means the test author hasn't had a chance to fix a report yet.
    private func brokenReportTheTestsWereAlreadyReworkedFor(_ id: NodeID) async -> BrokenTestReport? {
        let records = await ledger.allRecords().filter { $0.event.node == id }
        guard let testsFixed = records.last(where: {
            if case .testsFixed = $0.event.kind { return true }
            return false
        }), let previousRecord = records.last(where: {
            guard $0.position < testsFixed.position else { return false }
            if case .brokenTestReported = $0.event.kind { return true }
            return false
        }), case .brokenTestReported(let previous) = previousRecord.event.kind else {
            return nil
        }
        let personSteppedIn = records.contains {
            guard $0.position > previousRecord.position else { return false }
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
        return personSteppedIn ? nil : previous
    }
}
