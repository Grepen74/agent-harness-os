import Foundation

extension Reconciler {
    func review(_ node: NodeState, stage: ReviewStage, context: ReviewContext,
                        in directory: URL, run: RunID) async throws -> ReviewResult {
        guard let reviewer = team.reviewer else { throw AgentFailure("No reviewer is assigned.") }
        let folder = workspace.testFolder(for: node.spec) + "/"
        var tests: [String: String] = [:]
        for path in context.changedFiles where path.hasPrefix(folder) {
            let file = directory.appending(path: path)
            if FileManager.default.fileExists(atPath: file.path) {
                tests[path] = try String(contentsOf: file, encoding: .utf8)
            }
        }
        var instructions = ""
        if let path = policy.review.instructions {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw AgentFailure("Review instructions must name a repository-relative file.")
            }
            instructions = try String(contentsOf: directory.appending(path: path), encoding: .utf8)
        }
        let earlier = await failedReviews(of: node.id, stage: stage).map(\.result.allFindings)
        let request = ReviewRequest(
            stage: stage, spec: node.spec, acceptanceTests: tests, context: context,
            instructions: instructions, directory: directory, earlierFindings: earlier)
        var result = try await watchingUserGitState(node, run: run) { try await reviewer.review(request) }
        try Task.checkCancellation()
        let after = try await workspace.reviewContext(in: directory, against: context.baseBranch)
        guard after.commit == context.commit, after.fullDiff == context.fullDiff,
              Set(after.changedFiles) == Set(context.changedFiles) else {
            throw AgentFailure("The candidate changed during review. Check the reviewer, then add harness:retry.")
        }
        if stage == .change {
            let areas = node.spec.touches + context.changedFiles
            let isUI = areas.contains { path in
                path.split(separator: "/").contains { component in
                    let name = component.lowercased()
                    return name.hasSuffix("ui") || ["views", "windows"].contains(name)
                        || name.hasSuffix("view.swift") || name.hasSuffix("window.swift")
                }
            }
            if isUI {
                var missing: [String] = []
                if context.uiEvidence?.snapshotPaths.isEmpty != false { missing.append("UI snapshot evidence is required.") }
                if context.uiEvidence?.windowsOpened != true { missing.append("Evidence that windows open is required.") }
                if context.uiEvidence?.windowsClosed != true { missing.append("Evidence that windows close is required.") }
                if policy.review.level(for: areas) == .agentAndHuman {
                    if context.uiEvidence?.beforeScreenshot?.isEmpty != false {
                        missing.append("A before screenshot is required for human UI review.")
                    }
                    if context.uiEvidence?.afterScreenshot?.isEmpty != false {
                        missing.append("An after screenshot is required for human UI review.")
                    }
                }
                if !missing.isEmpty {
                    result = ReviewResult(passed: false, findings: result.findings + missing, testFindings: result.testFindings,
                                          followUps: result.followUps, model: result.model,
                                          unavailableModels: result.unavailableModels)
                }
            }
        }
        let reported = Set(await ledger.allRecords().flatMap { record -> [String] in
            guard record.event.node == node.id, case .reviewRecorded(let review) = record.event.kind else { return [] }
            return review.result.followUps ?? []
        })
        try await write(node.id, by: .reconciler, [.reviewRecorded(ReviewRecord(
            stage: stage, result: result, commit: context.commit, uiEvidence: context.uiEvidence))])
        // Later rounds and re-reviews often repeat a follow-up: the ticket gets each one once.
        if let followUps = result.followUps?.filter({ !reported.contains($0) }), !followUps.isEmpty {
            await tracker.comment(on: node.ticket, "📝 The \(stage.rawValue) review noted follow-ups. They don't block this "
                + "ticket; create tickets for those you want:\n" + followUps.map { "- \($0)" }.joined(separator: "\n"))
        }
        return result
    }

    /// This stage's failed reviews of the node's current work, oldest first. Rounds start over when a person
    /// resets attempts, has the tests rewritten (harness:retest) or replans or corrects the node: reviews of
    /// discarded work no longer count.
    private func failedReviews(of id: NodeID, stage: ReviewStage) async -> [ReviewRecord] {
        let records = await ledger.allRecords().filter { $0.event.node == id }
        let reset = records.lastIndex {
            switch $0.event.kind {
            case .attemptsReset, .replanned: return true
            case .phaseChanged(to: .specified): return $0.event.by.isHuman
            default: return false
            }
        }
        return records.dropFirst(reset.map { $0 + 1 } ?? 0).compactMap { record -> ReviewRecord? in
            guard case .reviewRecorded(let review) = record.event.kind,
                  review.stage == stage, !review.result.passed else { return nil }
            return review
        }
    }

    func returnReviewFindings(_ result: ReviewResult, stage: ReviewStage,
                                     node: NodeState, run: RunID, directory: URL? = nil) async throws -> String {
        let failures = await failedReviews(of: node.id, stage: stage)
        let escalated = failures.count >= policy.review.maxRounds
        let findings = (escalated ? failures.flatMap(\.result.allFindings) : result.allFindings).joined(separator: "\n")
        // Reviews that keep finding new problems usually mean the ticket is too big for one change: retrying the
        // same ticket rarely converges, so the escalation suggests splitting it before trying again.
        let reason = escalated
            ? "\(stage.rawValue) review didn't pass in \(failures.count) rounds. Findings:\n\(findings)\n"
                + "If each round found new problems, the ticket is probably too big for one change: split it into "
                + "smaller tickets (narrow its criteria and add the rest as new tickets, or harness:replan its parent "
                + "before building starts). Otherwise comment with guidance, then add harness:retry."
            : "\(stage.rawValue) review findings:\n\(findings)\nComment with guidance, then add harness:retry."
        // The implementer may not change the ticket's acceptance tests: problems in them go to the test author.
        let toTestAuthor = stage == .acceptanceTests || (result.testFindings != nil && !escalated)
        if stage == .change, toTestAuthor, let directory { try await workspace.resetForRework(directory) }
        var kinds: [EventKind] = [
            .runFinished(run: run, outcome: "review findings"),
            .phaseChanged(to: toTestAuthor ? .specified : .ready),
        ]
        if escalated { kinds.append(.flagSet(.escalated, reason: reason)) }
        try await write(node.id, by: .reconciler, kinds)
        if stage == .change, toTestAuthor {
            await tracker.comment(on: node.ticket, "🔁 Change review found problems in this ticket's acceptance tests, "
                + "sent back to the test author:\n\(findings)")
        } else {
            await tracker.comment(on: node.ticket, reason)
        }
        return "\(node.displayName) review findings → \(escalated ? "Needs human" : toTestAuthor ? "test author" : "implementer")"
    }
}
