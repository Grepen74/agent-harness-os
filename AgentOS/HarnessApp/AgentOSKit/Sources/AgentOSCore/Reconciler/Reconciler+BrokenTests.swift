import Foundation

extension Reconciler {
    /// Whether the node waits because a test of other work conflicts with it: the latest "Needs input" came with
    /// a broken-test report (same run, nothing started in between) routed as another test's conflict.
    /// The routing outcome is used because a test outside the test area may not look like another suite by name.
    func isWaitingOnOtherTest(_ node: NodeState) async -> Bool {
        await brokenTestWait(node) == .otherTestWaitingForPerson
    }

    /// Whether the node waits for a person after its own acceptance test was reported broken too often.
    func isWaitingOnOwnTest(_ node: NodeState) async -> Bool {
        await brokenTestWait(node) == .waitingForPerson
    }

    /// How the broken-test report the node's latest "Needs input" came from was routed; nil when it came from elsewhere.
    private func brokenTestWait(_ node: NodeState) async -> BrokenTestRoutingOutcome? {
        guard node.flags[.needsInput] != nil else { return nil }
        let records = await ledger.records(for: node.id)
        guard let flag = records.last(where: {
            if case .flagSet(.needsInput, _) = $0.event.kind { return true }
            return false
        }) else { return nil }
        for record in records.reversed() where record.position < flag.position {
            switch record.event.kind {
            case .brokenTestRouted(_, let outcome): return outcome
            // Older ledgers have no routing outcome; fall back to the test's name.
            case .brokenTestReported(let report):
                return isOwnTest(report.testName, of: node) ? .waitingForPerson : .otherTestWaitingForPerson
            case .runStarted: return nil
            default: continue
            }
        }
        return nil
    }

    func routeBrokenTest(
        _ report: BrokenTestReport,
        from node: NodeState,
        run: RunID,
        author: Participant,
        directory: URL,
        keptImplementation: [String] = []
    ) async throws -> String {
        try await resetForRework(node, in: directory)
        let kept = keptImplementation.isEmpty ? ""
            : "\nThe implementation so far (\(keptImplementation.count) files) is kept: the implementer continues from it."
        // Only the harness records where the test lives.
        var report = BrokenTestReport(testName: report.testName, reason: report.reason)
        let finished = EventKind.runFinished(run: run, outcome: "reported a broken test: \(report.testName)")

        let earlier = await brokenReportsSentBackSincePersonSteppedIn(node.id)
        // Settled reports about other tests don't count against this one, up to a cap for churning tests.
        let sameTest = earlier.filter { $0.testName == report.testName }
        let tries = sameTest.count >= Self.automaticTestReturns ? sameTest.count : earlier.count
        // Found outside the test area, a test is other work's whatever its name looks like.
        let outOfReach = outsideTestArea(report.testName, in: directory)
        let isOther = outOfReach != nil || !isOwnTest(report.testName, of: node)
        guard outOfReach == nil, sameTest.count < Self.automaticTestReturns,
              earlier.count < Self.automaticTestReturnsInAll else {
            let history = (earlier.map { "Earlier: \($0.testName): \($0.reason)" }
                + ["Now: \(report.testName): \(report.reason)"]).joined(separator: "\n")
            let next = """
                Next: if that test is out of date, change it on the default branch and commit; once the harness has \
                caught up, add harness:retry. Otherwise comment how to proceed, then add harness:retry.
                """
            let reason = if let outOfReach {
                """
                \(report.testName) isn't one of this ticket's acceptance tests. Its expectations conflict with this \
                ticket, and it lives in \(outOfReach), outside \(workspace.updatableTestAreas.joined(separator: ", ")), \
                where no agent may change tests:
                \(history)
                \(next)
                """
            } else if isOther {
                """
                \(report.testName) isn't one of this ticket's acceptance tests. Its expectations conflict with this \
                ticket, and the test author couldn't settle it in \(tries) tries (it may only update another \
                item's test where this ticket's criteria deliberately change what that test checks):
                \(history)
                \(next)
                """
            } else {
                """
                The test author already reworked these tests \(tries) times after broken-test reports:
                \(history)
                Next: review the reports, comment with guidance, then add harness:retry. To have the tests written \
                again from scratch, add harness:retest instead.
                """
            }
            // As committed on the leaf's branch now (rework just discarded everything else): a retry compares
            // against it to tell whether a person fixed the test meanwhile.
            if isOther, let file = outOfReach ?? declaringFiles(of: report.testName, in: directory).first {
                report.testFile = file
                report.testFileDigest = Hashing.digest(ofFiles: [file], in: directory)
            }
            try await write(node.id, by: author, [
                finished,
                .brokenTestReported(report),
                .brokenTestRouted(testName: report.testName, outcome: isOther ? .otherTestWaitingForPerson : .waitingForPerson),
                .phaseChanged(to: .ready),
                .flagSet(.needsInput, reason: reason),
            ])
            await tracker.comment(on: node.ticket, (isOther
                ? "\(Self.needsInputMarker): another test conflicts with this ticket.\n\(reason)"
                : """
                \(Self.needsInputMarker): broken acceptance test \(report.testName): \(report.reason)
                waiting for a person: the test author already reworked these tests.
                \(reason)
                """) + kept)
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
            sent back to the test author.\(otherNote)\(kept)
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

    /// The file a reported test lives in when that's outside the updatable test areas, where agents may not change
    /// tests: the test author can't settle it, so a person is asked straight away. Nil when it's inside, or not found.
    private func outsideTestArea(_ testName: String, in directory: URL) -> String? {
        guard !workspace.updatableTestAreas.isEmpty else { return nil }
        let files = declaringFiles(of: testName, in: directory)
        return files.contains(where: workspace.isInUpdatableTestArea) ? nil : files.first
    }

    /// The file a reported test lives in when that's inside the updatable test areas, where the test author may
    /// update it. Nil when it's outside, or not found.
    func reachableTestFile(_ testName: String, in directory: URL) -> String? {
        declaringFiles(of: testName, in: directory).first(where: workspace.isInUpdatableTestArea)
    }

    /// The files, relative to the repo's top folder, that declare the reported test's suite, or the file the
    /// report names by path.
    private func declaringFiles(of testName: String, in directory: URL) -> [String] {
        let root = directory.standardizedFileURL.path + "/"
        let relative = { (url: URL) -> String? in
            let path = url.standardizedFileURL.path
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
        }
        if testName.contains("/") {
            let named = directory.appending(path: testName.split(separator: ":").first.map(String.init) ?? testName)
            guard FileManager.default.fileExists(atPath: named.path), let path = relative(named) else { return [] }
            return [path]
        }
        // A declaration starts its line (after attributes and modifiers), so a suite named in a string or a
        // comment, say a test fixture's source text, doesn't count.
        guard let suite = testName.split(separator: ".").first.map(String.init), suite != testName,
              let declaration = try? NSRegularExpression(
                  pattern: #"^[ \t]*(?:@\w+(?:\([^)\n]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private|final|open)\s+)*(?:struct|class|enum|actor)\s+"#
                      + NSRegularExpression.escapedPattern(for: suite) + #"\b"#,
                  options: .anchorsMatchLines)
        else { return [] }
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var declaredIn: [String] = []
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8),
                  declaration.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
                  let path = relative(url) else { continue }
            declaredIn.append(path)
        }
        return declaredIn
    }

    /// How often reports about the same test go back to the test author before a person is asked: one rewrite can
    /// fix a test and still leave another one broken, so the second try is worth more than a person's wait.
    static let automaticTestReturns = 2
    /// How many broken-test reports, about any tests, go back to the test author before a person is asked: each
    /// report may name a different test, but endless churn needs a person too.
    static let automaticTestReturnsInAll = 4

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
