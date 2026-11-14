import Foundation

extension Reconciler {
    /// Left side of the V: a fresh branch for the leaf, and its acceptance tests as the branch's first commit.
    func authorTests(_ node: NodeState) async throws -> String {
        let run = Self.newRunID()
        let author = Participant.agent(run: run, role: .testAuthor)
        let keep = await keepsEarlierTests(node)
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .testAuthor)], expecting: node.version)
        let directory = keep
            ? try await workspace.createWorktree(for: node.id, keeping: workspace.testFolder(for: node.spec))
            : try await workspace.createWorktree(for: node.id)
        let task = await makeTask(node, run: run, in: directory, log: agentLog(node, run),
                                  for: .testAuthor, includeComments: false)
        let own = workspace.testFolder(for: node.spec) + "/"
        let report: AgentReport
        do {
            report = try await watchingUserGitState(node, run: run) { try await team.testAuthor.writeAcceptanceTests(task) }
            try Task.checkCancellation()
        } catch {
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"),
                .flagSet(.escalated, reason: "Couldn't write acceptance tests: \(error)")])
            return "\(node.displayName) test authoring failed → escalated"
        }
        let questions = policy.questions(in: report, role: .testAuthor)
        guard questions.isEmpty else {
            // Tests written on a guess aren't kept: the branch starts over once the questions are answered.
            try? await workspace.removeWorktree(for: node.id)
            return try await raise(questions, on: node, by: author, run: run, role: .testAuthor)
        }
        try await recordSuggestions(report.questions, on: node, role: .testAuthor, by: author)
        let assumptions = policy.assumptions(in: report)
        let testFiles: [String]
        do {
            let changed = try await workspace.commitAll(in: directory, message: "\(node.spec.id): acceptance tests", author: run)
            // After the commit, so the check sees everything the author wrote (changes are compared commit to commit).
            let outside = try await workspace.changedFiles(in: directory).filter { !$0.hasPrefix(own) }
            guard outside.isEmpty, changed != nil else {
                let none = report.questions.isEmpty ? "no tests written"
                    : "no tests written: it reported questions with suggested answers but didn't write tests on them"
                throw AgentFailure(changed == nil ? none : "wrote outside its own test folder \(own): \(outside.joined(separator: ", "))")
            }
            testFiles = try await workspace.changedFiles(in: directory).filter { $0.hasPrefix(own) }
        } catch {
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"),
                .flagSet(.escalated, reason: "Couldn't write acceptance tests: \(error)")])
            return "\(node.displayName) test authoring failed → escalated"
        }

        // Before the review: tests that can't compile come straight back, without using up a review round.
        let preflight = await acceptanceTestPreflight.compileTests(
            in: directory,
            testFolder: workspace.testFolder(for: node.spec),
            expectedAPI: report.expectedAPI
        )
        try Task.checkCancellation()
        switch preflight {
        case .compiled, .skipped:
            break
        case .diagnostics(let diagnostics, let fullLog):
            return try await returnAcceptanceTests(
                diagnostics,
                fullLog: fullLog,
                report: report,
                assumptions: assumptions,
                node: node,
                run: run,
                author: author,
                directory: directory
            )
        }

        if team.reviewer != nil, policy.review.requiresReview {
            let context = try await workspace.reviewContext(in: directory, against: policy.review.baseBranch)
            if policy.review.level(for: node.spec.touches + context.changedFiles) != .none {
                let result = try await review(node, stage: .acceptanceTests, context: context, in: directory, run: run)
                if !result.passed {
                    return try await returnReviewFindings(result, stage: .acceptanceTests, node: node, run: run)
                }
            }
        }

        // Under "assume and report", a leaf whose work rests on assumptions waits for a person to see its tests,
        // unless they already answered something on it. Questions about what users observe stopped it above.
        let state = await ledger.workingState()
        let review = policy.guesswork == .assumeAndReport && (!assumptions.isEmpty
            || (!state.assumptions(for: node.id).isEmpty && state.clarifications(for: node.id).isEmpty))
        let reviewReason = "Review the acceptance tests and assumptions, then add harness:build"
        try await write(node.id, by: author, [
            .runFinished(run: run, outcome: "acceptance tests committed"), .testsFixed(digest: testsDigest(node, in: directory)),
            .expectedAPIReported(report.expectedAPI),
            .assumptionsReported(role: .testAuthor, assumptions: assumptions), .phaseChanged(to: .ready)]
            + (review ? [.flagSet(.needsInput, reason: reviewReason)] : []))
        let reviewNote = review ? """

            \(Self.needsInputMarker): \(reviewReason.prefix(1).lowercased() + reviewReason.dropFirst()) to approve them as they are, \
            or comment what to change and add harness:retry.
            """ : ""
        await tracker.comment(on: node.ticket, """
            🧪 Acceptance tests written on branch \(workspace.branch(for: node.id)):
            \(Self.testListing(testFiles, in: directory))\(Self.assumptionsNote("Assumptions this work rests on", await ledger.workingState().assumptions(for: node.id)))\(reviewNote)
            """)
        return "\(node.displayName) acceptance tests written on branch \(workspace.branch(for: node.id)) → " + (review ? "waiting for review" : "Ready")
    }

    /// Tests that came back (review findings, compiler errors, a broken-test report) are fixed in place rather
    /// than rewritten blind: every rewrite risks new mistakes. A person asking for new tests (retest) or a
    /// replan starts them over.
    private func keepsEarlierTests(_ node: NodeState) async -> Bool {
        guard node.latestTestFeedback != nil else { return false }
        let history = await ledger.allRecords().filter { $0.event.node == node.id }
        guard let lastRun = history.lastIndex(where: {
            if case .runStarted(_, .testAuthor) = $0.event.kind { return true }
            return false
        }) else { return false }
        return !history[(lastRun + 1)...].contains {
            switch $0.event.kind {
            case .replanned: return true
            case .phaseChanged(to: .specified):
                if case .human = $0.event.by { return true }
                return false
            default: return false
            }
        }
    }

    private func returnAcceptanceTests(
        _ diagnostics: [CompilerDiagnostic],
        fullLog: String,
        report: AgentReport,
        assumptions: [String],
        node: NodeState,
        run: RunID,
        author: Participant,
        directory: URL
    ) async throws -> String {
        let mistakes = diagnostics.filter { $0.classification == .testAuthorMistake }
        guard let first = mistakes.first else {
            return "\(node.displayName) acceptance-test preflight found only expected diagnostics"
        }
        let artifact = try artifacts.put(
            named: "\(node.id)-\(run)-acceptance-test-preflight.log",
            contents: Data(fullLog.utf8)
        )
        let commit = (try? await workspace.head(of: directory)) ?? "acceptance-tests"
        let summary = "\(first.file):\(first.line): \(first.message)"
        let own = workspace.testFolder(for: node.spec) + "/"
        let clashes = mistakes.contains { !$0.file.hasPrefix(own) }
            ? "\n\nErrors in other test files mean your tests declare names those files also declare. All test files "
                + "compile together: make your helper types `private`, or nest them inside your suite."
            : ""
        let details = "The acceptance tests didn't compile:\n"
            + Self.uniqueLines(mistakes.map { "\($0.file):\($0.line): \($0.message)" }).prefix(20).joined(separator: "\n")
            + clashes
        let evidence = Evidence(
            check: "acceptance-test compilation",
            passed: false,
            summary: summary,
            specHash: node.spec.specHash,
            builtBy: run,
            checkedBy: run,
            artifactPath: artifact.path,
            artifactSHA256: artifact.sha256,
            commit: commit,
            failureClassification: nil,
            details: details
        )
        let history = await ledger.records(for: node.id)
        // A person stepping in (retest, retry, an answer) gives the test author a fresh set of attempts.
        let lastReset = history.lastIndex {
            guard case .human = $0.event.by else { return false }
            switch $0.event.kind {
            case .attemptsReset, .flagCleared(.needsInput), .phaseChanged(to: .specified): return true
            default: return false
            }
        }
        let authorAttempts = history[(lastReset.map { $0 + 1 } ?? 0)...].filter {
            if case .runStarted(_, .testAuthor) = $0.event.kind { return true }
            return false
        }.count
        let reachedLimit = authorAttempts >= policy.maxAttempts
        let reason = "Acceptance tests don't compile. First error: \(summary)"
        var kinds: [EventKind] = [
            .runFinished(run: run, outcome: "acceptance tests did not compile"),
            .expectedAPIReported(report.expectedAPI),
            .assumptionsReported(role: .testAuthor, assumptions: assumptions),
            .acceptanceTestPreflightFailed(evidence),
        ]
        if reachedLimit {
            kinds.append(.flagSet(.needsInput, reason: reason))
        }
        try await write(node.id, by: author, kinds)

        let files = Set(mistakes.map(\.file)).sorted()
        let listed = Self.uniqueLines(mistakes.map { "\($0.file):\($0.line): \($0.message)" }).prefix(20).joined(separator: "\n")
        let heading = reachedLimit
            ? "\(Self.needsInputMarker): Acceptance tests don't compile."
            : "↩️ Acceptance tests don't compile; returned to the test author."
        await tracker.comment(on: node.ticket, """
            \(heading)
            Affected test files: \(files.joined(separator: ", "))
            \(listed)
            Full compiler log: \(artifact.path)
            \(reachedLimit ? "Fix the tests or comment with guidance, then add harness:retry." : "The test author will rerun with these diagnostics.")
            """)
        return reachedLimit
            ? "\(node.displayName) acceptance tests don't compile → Needs input"
            : "\(node.displayName) acceptance tests don't compile → returned to test author"
    }

    /// Each test file with the tests in it, so a person can review them before build.
    static func testListing(_ files: [String], in directory: URL) -> String {
        files.sorted().map { file in
            let text = (try? String(contentsOf: directory.appending(path: file), encoding: .utf8)) ?? ""
            return (["- \(file)"] + testNames(in: text).map { "  - \($0)" }).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// `@Test("…")` display names (Swift Testing), else the function names: `@Test func x()` and XCTest's `func testX()`.
    static func testNames(in source: String) -> [String] {
        let patterns = [#"@Test\s*\(\s*"((?:[^"\\]|\\.)*)""#, #"@Test(?:\s*\([^)]*\))?\s+(?:@\w+\s+)*func\s+(\w+)"#,
                        #"func\s+(test\w*)\s*\("#]
        var names: [String] = []
        var displayed = Set<Int>()
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let found = Range(match.range(at: 1), in: source) else { continue }
                let line = source[..<found.lowerBound].filter { $0 == "\n" }.count
                // A named @Test and its function are one test: keep the name.
                if index == 0 { displayed.insert(line) } else if displayed.contains(line) || displayed.contains(line - 1) { continue }
                let name = String(source[found])
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    private static func uniqueLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }
}
