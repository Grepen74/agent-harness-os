import Foundation

extension Reconciler {
    /// Left side of the V: a fresh branch for the leaf, and its acceptance tests as the branch's first commit.
    func authorTests(_ node: NodeState) async throws -> String {
        let run = Self.newRunID()
        let author = Participant.agent(run: run, role: .testAuthor)
        let leftover = node.testDraft == nil ? await leftUncommittedTests(node) : false
        let keepsEarlier = await keepsEarlierTests(node)
        try await write(node.id, by: .reconciler, agentRunStarted(run, .testAuthor), expecting: node.version)
        // A failed run's draft already holds the earlier tests it kept: a fresh worktree and the draft on top.
        var continuesDraft = node.testDraft != nil
        if leftover, FileManager.default.fileExists(atPath: workspace.worktree(for: node.id).path) {
            let worktree = workspace.worktree(for: node.id)
            do {
                continuesDraft = !(try await keepTestDraft(worktree, of: node)).isEmpty
            } catch {
                // Starting over would replace the worktree that holds the only copy of these tests.
                let reason = "Couldn't keep the tests an earlier run left (\(error)). They are still uncommitted in "
                    + "\(worktree.path)."
                try await write(node.id, by: author, [
                    .runFinished(run: run, outcome: "failed: \(error)"), .flagSet(.escalated, reason: reason)])
                await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(reason)\nWhen checked, add label harness:retry.")
                return "\(node.displayName) escalated: \(reason)"
            }
        }
        if !continuesDraft { try? await workspace.forgetTestDraft(for: node.id) }
        let keep = !continuesDraft && keepsEarlier
        let kept = [workspace.testFolder(for: node.spec)] + node.updatedOtherTests
        var directory = keep
            ? try await workspace.createWorktree(for: node.id, keeping: kept)
            : try await workspace.createWorktree(for: node.id)
        let draft = continuesDraft ? try await workspace.restoreTestDraft(for: node.id, in: directory) : []
        if continuesDraft, draft.isEmpty, keepsEarlier {
            directory = try await workspace.createWorktree(for: node.id, keeping: kept)
        }
        let draftCheck = draft.isEmpty ? nil : await checkDraft(node, run: run, in: directory)
        let task = await makeTask(node, run: run, in: directory, log: agentLog(node, run),
                                  for: .testAuthor, unfinishedWork: draft, draftCheck: draftCheck)
        let own = workspace.testFolder(for: node.spec) + "/"
        let report: AgentReport
        do {
            report = try await withScratchDirectory(task.scratchDirectory) {
                try await recordingFallback(node.id, run: run) {
                    try await watchingUserGitState(node, run: run) { try await team.testAuthor.writeAcceptanceTests(task) }
                }
            }
            try Task.checkCancellation()
        } catch let error as UserGitStateChanged {
            // Not something another attempt fixes: a human checks what happened to their repo first.
            let kept = (try? await keepTestDraft(directory, of: node)) ?? []
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"), .testDraftKept(run: run, files: kept),
                .flagSet(.escalated, reason: "Couldn't write acceptance tests: \(error)")])
            return "\(node.displayName) test authoring failed → escalated"
        } catch {
            return try await keepFailedTestDraft(error, on: node, run: run, author: author, in: directory)
        }
        let questions = policy.questions(in: report, role: .testAuthor)
        guard questions.isEmpty else {
            // Tests written on a guess aren't kept: the branch starts over once the questions are answered.
            try? await workspace.removeWorktree(for: node.id)
            try? await workspace.forgetTestDraft(for: node.id)
            return try await raise(questions, on: node, by: author, run: run, role: .testAuthor)
        }
        try await recordSuggestions(report.questions, on: node, role: .testAuthor, by: author)
        let assumptions = policy.assumptions(in: report)
        let testFiles: [String]
        let updatedOtherTests: [String]
        // Tests fixed in place keep the earlier runs' updates to other work's tests, even when this run doesn't
        // list them again: it was asked to fix something else.
        let updatable = updatableOtherTests(report.updatedTests + (keep || continuesDraft ? node.updatedOtherTests : []), of: node)
        do {
            // The author may have added placeholder code so its tests build and run; only its tests, and other
            // work's tests it says this item deliberately changes, are committed.
            try await workspace.discardChanges(keeping: [workspace.testFolder(for: node.spec)] + updatable, in: directory)
            let changed = try await workspace.commitAll(in: directory, message: "\(node.spec.id): acceptance tests", author: run)
            // After the commit, so the check sees everything the author wrote (changes are compared commit to commit).
            let changedFiles = try await workspace.changedFiles(in: directory)
            // A listed folder keeps the files in it.
            let isUpdated = { (file: String) in updatable.contains { file == $0 || file.hasPrefix($0 + "/") } }
            let protected = Set(policy.protectedPathViolations(changedFiles))
            updatedOtherTests = changedFiles.filter { !$0.hasPrefix(own) && isUpdated($0) && !protected.contains($0) }
            let outside = changedFiles.filter { !$0.hasPrefix(own) && !updatedOtherTests.contains($0) }
            guard outside.isEmpty, changed != nil else {
                let none = report.questions.isEmpty ? "no tests written"
                    : "no tests written: it reported questions with suggested answers but didn't write tests on them"
                throw AgentFailure(changed == nil ? none : "wrote outside its own test folder \(own): \(outside.joined(separator: ", "))")
            }
            testFiles = try await workspace.changedFiles(in: directory).filter { $0.hasPrefix(own) }
            // Committed: the draft is in the branch now.
            try? await workspace.forgetTestDraft(for: node.id)
        } catch {
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"),
                .flagSet(.escalated, reason: "Couldn't write acceptance tests: \(error)")])
            return "\(node.displayName) test authoring failed → escalated"
        }

        let otherTestsEvent = EventKind.otherTestsUpdated(
            files: updatedOtherTests, digest: Hashing.digest(ofFiles: updatedOtherTests, in: directory))
        // Tests that come back are fixed in place: remember which other tests this run updated, so the next run
        // keeps them.
        let rememberOtherTests = { [self] in
            if !updatedOtherTests.isEmpty || !node.updatedOtherTests.isEmpty {
                try await write(node.id, by: author, [otherTestsEvent])
            }
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
            try await rememberOtherTests()
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
                    try await rememberOtherTests()
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
        // Failed test-author runs aren't the implementer's attempts.
        let reset = await onlyTestAuthorFailures(node)
        try await write(node.id, by: author, [
            .runFinished(run: run, outcome: "acceptance tests committed"), .testsFixed(digest: testsDigest(node, in: directory))]
            + (reset ? [.attemptsReset] : [])
            + (updatedOtherTests.isEmpty ? [] : [otherTestsEvent])
            + [.expectedAPIReported(report.expectedAPI),
            .assumptionsReported(role: .testAuthor, assumptions: assumptions), .phaseChanged(to: .ready)]
            + (review ? [.flagSet(.needsInput, reason: reviewReason)] : []))
        let reviewNote = review ? """

            \(Self.needsInputMarker): \(reviewReason.prefix(1).lowercased() + reviewReason.dropFirst()) to approve them as they are, \
            or comment what to change and add harness:retry.
            """ : ""
        await tracker.comment(on: node.ticket, """
            🧪 Acceptance tests written on branch \(workspace.branch(for: node.id)):
            \(Self.testListing(testFiles, in: directory))\(Self.updatedTestsNote(updatedOtherTests))\(Self.assumptionsNote("Assumptions this work rests on", await ledger.workingState().assumptions(for: node.id)))\(reviewNote)
            """)
        return "\(node.displayName) acceptance tests written on branch \(workspace.branch(for: node.id)) → " + (review ? "waiting for review" : "Ready")
    }

    /// A failed run (it ran out of time, say) keeps what it wrote as a draft the next run continues, rather than
    /// escalating at once: a person only steps in when runs stop making progress or the attempts run out.
    private func keepFailedTestDraft(
        _ error: any Error, on node: NodeState, run: RunID, author: Participant, in directory: URL
    ) async throws -> String {
        if Task.isCancelled {
            // Stopped (by a person, or closing the window): the draft is kept and recorded directly, since a stopped
            // task's writes are refused. The run's end is recorded by the harness's safety net.
            if let kept = try? await keepTestDraft(directory, of: node) {
                _ = try? await ledger.append([LedgerEvent(node: node.id, by: author, kind: .testDraftKept(run: run, files: kept))])
            }
            throw error
        }
        let kept: [String]
        do {
            kept = try await keepTestDraft(directory, of: node)
        } catch let keeping {
            // The next run would start from a fresh worktree, losing this run's work.
            let reason = "Couldn't keep the failed test author's draft (\(keeping)). It is still uncommitted in " +
                "\(directory.path). Run failure: \(error)"
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"), .attemptFailed(summary: "\(error)"),
                .flagSet(.escalated, reason: reason)])
            await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(reason)\nWhen checked, add label harness:retry.")
            return "\(node.displayName) escalated: \(reason)"
        }
        // The draft's fingerprint, so only a run that left it unchanged counts as "the same failure twice".
        let progress = kept.isEmpty ? "no draft"
            : "draft of \(kept.count) files, \(Hashing.digest(ofFiles: kept, in: directory).prefix(8))"
        try await write(node.id, by: author, [
            .runFinished(run: run, outcome: "failed: \(error)"), .attemptFailed(summary: "\(Self.firstLine(of: error)) (\(progress))"),
            .testDraftKept(run: run, files: kept)])
        let retry = kept.isEmpty ? "will retry" : "will continue its draft of \(kept.count) files"
        return try await escalateIfNeeded(node.id) ?? "\(node.displayName) test author failed (\(error)); \(retry)"
    }

    /// The error's first line without the agent's output after it, which differs from run to run.
    static func firstLine(of error: any Error) -> String {
        let text = "\(error)"
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        return line.components(separatedBy: ": ").first ?? line
    }

    /// Saves in a task of its own: a stopped run's task is cancelled, and its git commands would refuse to start.
    private func keepTestDraft(_ directory: URL, of node: NodeState) async throws -> [String] {
        let workspace = workspace, id = node.id
        return try await Task { try await workspace.saveTestDraft(directory, for: id) }.value
    }

    /// The last test-author run failed or was abandoned (by a harness without drafts, or a restart) and nothing
    /// since asked for new tests: what it left uncommitted in the worktree is a draft to continue.
    private func leftUncommittedTests(_ node: NodeState) async -> Bool {
        let history = await ledger.records(for: node.id)
        guard let lastRun = history.lastIndex(where: {
            if case .runStarted(_, .testAuthor) = $0.event.kind { return true }
            return false
        }) else { return false }
        let after = history[(lastRun + 1)...]
        let failed = after.contains {
            guard case .runFinished(_, let outcome) = $0.event.kind else { return false }
            return outcome.hasPrefix("failed") || outcome.hasPrefix("abandoned") || outcome.hasPrefix("stopped")
        }
        return failed && !after.contains {
            switch $0.event.kind {
            case .testsFixed, .replanned, .testDraftKept, .questionsRaised(.testAuthor, _): return true
            case .signalAccepted(_, let command, _): return command == .retest
            default: return false
            }
        }
    }

    /// Whether every failed attempt since the last reset was a test-author run's.
    private func onlyTestAuthorFailures(_ node: NodeState) async -> Bool {
        guard node.failedAttempts > 0 else { return false }
        var counted = 0
        for record in await ledger.records(for: node.id).reversed() where counted < node.failedAttempts {
            switch record.event.kind {
            case .attemptFailed:
                guard case .agent(_, .testAuthor) = record.event.by else { return false }
                counted += 1
            case .evidenceRecorded(let evidence) where !evidence.passed:
                return false
            default:
                continue
            }
        }
        return counted == node.failedAttempts
    }

    /// How long the harness's own run of a draft's suite may take before the agent starts anyway.
    static let draftCheckLimit: Duration = .seconds(600)

    /// Before a test author continues a draft, the harness runs its suite once, so the run starts from what
    /// actually fails rather than spending its time rebuilding everything to find out.
    private func checkDraft(_ node: NodeState, run: RunID, in directory: URL) async -> String {
        let suite = node.spec.testTarget, checks = checks
        let output: CheckOutput? = await withTaskGroup(of: CheckOutput?.self) { group in
            group.addTask { await checks.runChecks(in: directory, only: suite) }
            group.addTask {
                try? await Task.sleep(for: Self.draftCheckLimit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let output else {
            return "The harness's run of \(suite) didn't finish within \(Self.draftCheckLimit). Don't run the whole " +
                "suite again: build, and run only the tests you change."
        }
        let artifact = try? artifacts.put(named: "\(node.id)-\(run)-draft-check.log", contents: Data(output.log.utf8))
        let tail = output.log.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
        let result = output.passed
            ? "\(suite) passed against the draft's placeholders: tests of new behaviour should fail against them, so check those."
            : "\(suite) failed: \(output.summary)"
        return result + (artifact.map { "\nFull log: \($0.path)" } ?? "") + "\nLast lines:\n" + tail
    }

    /// Files the test author says it updated in other work's tests: only test files of the updatable test areas,
    /// never protected ones. Anything else it changed is thrown away.
    private func updatableOtherTests(_ files: [String], of node: NodeState) -> [String] {
        let own = workspace.testFolder(for: node.spec)
        let areas = workspace.updatableTestAreas
        let candidates = Set(files.map { (file: String) -> String in
            var file = file
            while file.hasPrefix("./") { file.removeFirst(2) }
            while file.hasSuffix("/") { file.removeLast() }
            return file
        }).filter { (file: String) -> Bool in
            // Something inside an area, never a whole area, the own folder or a folder holding it.
            areas.contains { !$0.isEmpty && file.hasPrefix($0) && file.count > $0.count }
                && file != own && !file.hasPrefix(own + "/") && !own.hasPrefix(file + "/")
                && !file.split(separator: "/").contains("..")
        }
        let protected = Set(policy.protectedPathViolations(Array(candidates)))
        return candidates.subtracting(protected).sorted()
    }

    static func updatedTestsNote(_ files: [String]) -> String {
        guard !files.isEmpty else { return "" }
        return "\n\nOther work's tests updated because this ticket deliberately changes what they check:\n"
            + files.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Tests that came back (review findings, compiler errors, a broken-test report) are fixed in place rather
    /// than rewritten blind: every rewrite risks new mistakes. A person asking for new tests (retest) or a
    /// replan starts them over.
    private func keepsEarlierTests(_ node: NodeState) async -> Bool {
        guard node.latestTestFeedback != nil else { return false }
        let history = await ledger.records(for: node.id)
        guard let lastRun = history.lastIndex(where: {
            if case .runStarted(_, .testAuthor) = $0.event.kind { return true }
            return false
        }) else { return false }
        // Only a retest or a replan asks for new tests; feedback with harness:retry is for fixing these.
        return !history[(lastRun + 1)...].contains {
            switch $0.event.kind {
            case .replanned: return true
            case .signalAccepted(_, let command, _): return command == .retest
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
