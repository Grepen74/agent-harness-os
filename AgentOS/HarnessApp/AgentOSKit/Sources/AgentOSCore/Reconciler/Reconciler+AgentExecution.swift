import Foundation

extension Reconciler {
    /// A fresh file for the run's own output (see `AgentLog`). Not having one never stops the work.
    func agentLog(_ node: NodeState, _ run: RunID) -> URL? {
        try? artifacts.liveFile(named: AgentLog.fileName(node: node.id, run: run))
    }

    /// Agents may only change their own worktree and branch. Anything else in your repo (fetched or new refs,
    /// stashes, config, hooks) means an agent got around its denied tools. With agents running side by side,
    /// the change can't be pinned on one: every agent that ran at the same time is named, and each of them
    /// notices the change itself too.
    func watchingUserGitState<T>(_ node: NodeState, run: RunID, _ agent: () async throws -> T) async throws -> T {
        // The span covers both snapshots: whatever changed between them happened during it.
        clock += 1
        agentRuns[run] = AgentRunSpan(ticket: node.displayName, start: clock)
        defer {
            clock += 1
            agentRuns[run]?.end = clock
            pruneAgentRuns()
        }
        let before = try await workspace.userGitState()
        let result = try await agent()
        try Task.checkCancellation()
        let after = try await workspace.userGitState()
        guard after != before, let mine = agentRuns[run] else { return result }
        let changed = Set(before).symmetricDifference(after).compactMap { $0.split(separator: " ").last.map(String.init) }
        let alongside = agentRuns.filter { $0.key != run && $0.value.start <= clock && ($0.value.end ?? .max) > mine.start }
            .map(\.value.ticket)
        throw UserGitStateChanged(names: Array(Set(changed)).sorted(), alongside: Array(Set(alongside)).sorted())
    }

    private func pruneAgentRuns() {
        guard let oldestWatch = agentRuns.values.filter({ $0.end == nil }).map(\.start).min() else {
            agentRuns.removeAll()
            return
        }
        agentRuns = agentRuns.filter { _, span in
            guard let end = span.end else { return true }
            return end > oldestWatch
        }
    }

    struct AgentRunSpan {
        let ticket: String
        let start: Int
        var end: Int?
    }

    func withScratchDirectory<T>(_ directory: URL, operation: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation()
    }

    func makeAgentContext(_ key: String) async -> AgentContext {
        let documents = workspace.designDocumentPaths
        guard let ticket = await tracker.ticket(key) else {
            return AgentContext(designDocumentPaths: documents)
        }
        var tickets = await tracker.contextTickets()
        var linkedCount = 0
        for reference in AgentContextBuilder.referencedKeys(in: ticket, repository: tracker.contextRepository) {
            if linkedCount == 10 { break }
            if tickets.contains(where: { $0.key == reference }) {
                linkedCount += 1
            } else if let linked = await tracker.ticket(reference) {
                tickets.append(linked)
                linkedCount += 1
            }
        }
        if let parent = ticket.parentKey {
            if !tickets.contains(where: { $0.key == parent }), let issue = await tracker.ticket(parent) {
                tickets.append(issue)
            }
            let state = await ledger.workingState()
            for sibling in state.nodes.values where sibling.ticket != key {
                guard let parentNode = state.node(forTicket: parent),
                      sibling.spec.parent == parentNode.id,
                      !tickets.contains(where: { $0.key == sibling.ticket }),
                      let issue = await tracker.ticket(sibling.ticket) else { continue }
                tickets.append(issue)
            }
        }
        return AgentContextBuilder.build(ticket: ticket, tickets: tickets, repository: tracker.contextRepository,
                                         designDocumentPaths: documents)
    }

    func makeTask(_ node: NodeState, run: RunID, in directory: URL, log: URL?,
                          for role: AgentRole, includeComments: Bool = true) async -> AgentTask {
        let labels = await tracker.ticket(node.ticket)?.labels.map(\.name) ?? []
        let state = await ledger.workingState()
        let context = await makeAgentContext(node.ticket)
        return AgentTask(
            spec: node.spec, run: run, directory: directory, testFolder: workspace.testFolder(for: node.spec),
            scratchDirectory: directory.appending(path: ".agentos/scratch/\(run)", directoryHint: .isDirectory),
            context: workspace.agentContext, attempt: node.failedAttempts + 1,
            // The test author needs the latest problem with its tests; older reports may be about tests since rewritten.
            previousFailure: role == .testAuthor
                ? node.latestTestFeedback ?? node.recentFailures.last
                : node.latestReviewFeedback
                    ?? node.brokenTestReports.last?.reason
                    ?? node.evidence.last(where: { $0.check == "acceptance-test compilation" })?.summary
                    ?? node.recentFailures.last,
            simulationHints: Set(labels.filter { $0.hasPrefix("sim:") }), log: log,
            clarifications: state.clarifications(for: node.id), guesswork: policy.guesswork,
            expectedAPI: node.expectedAPI, ticketKey: node.ticket,
            agentContext: includeComments ? context : context.withoutComments())
    }

    static func newRunID() -> RunID { "run-" + UUID().uuidString.prefix(6).lowercased() }
}
