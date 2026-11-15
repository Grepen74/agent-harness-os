import Foundation

extension Reconciler {
    /// An escalated node the diagnoser hasn't looked at yet. It is the only step an escalated node gets.
    func wantsDiagnosis(_ node: NodeState) -> Bool {
        team.diagnoser != nil && node.needsDiagnosis && node.flags[.escalated] != nil && node.activeRun == nil
            && !node.ticketClosed
    }

    /// Stops a ticket whose agents keep going round (tests and review findings going back and forth, say) before
    /// the next test-author or implementer run, however each run ended. Any person acting on it starts a new budget.
    func stopForRunBudget(_ node: NodeState) async throws -> String? {
        guard node.agentRunsSinceHuman >= policy.maxAgentRuns else { return nil }
        let reason = "Agents ran \(node.agentRunsSinceHuman) times on this ticket since a person last acted on it "
            + "(limit \(policy.maxAgentRuns)). It keeps going round: the ticket may be too big or unclear. Split it into "
            + "smaller tickets, or comment with guidance, then add harness:retry."
        try await write(node.id, by: .reconciler, [.flagSet(.escalated, reason: reason)], expecting: node.version)
        await tracker.comment(on: node.ticket, "🛑 " + reason)
        return "\(node.displayName) run budget used up → Needs human"
    }

    static let diagnosisHistoryLimit = 80
    static let diagnosisLogLimit = 4

    /// Reads the escalation, the node's history and its agents' recent logs, and posts the diagnoser's reading
    /// on the ticket. The node stays escalated: only a person acts on the suggestion.
    func diagnose(_ node: NodeState) async throws -> String? {
        guard let diagnoser = team.diagnoser, let escalation = node.flags[.escalated] else { return nil }
        let run = Self.newRunID()
        let author = Participant.agent(run: run, role: .diagnoser)
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .diagnoser)], expecting: node.version)
        let records = await ledger.records(for: node.id)
        let history = records.suffix(Self.diagnosisHistoryLimit).map {
            "\($0.event.at.ISO8601Format()) \($0.event.by.label): \($0.event.kind.summary)"
        }
        let log = agentLog(node, run)
        let worktree = workspace.worktree(for: node.id)
        let snapshot = FileManager.default.fileExists(atPath: worktree.path) ? nil : try? await workspace.createSnapshot()
        let request = DiagnosisRequest(
            ticketKey: node.ticket, title: node.spec.title, acceptanceCriteria: node.spec.acceptanceCriteria,
            escalation: escalation, history: history, logs: recentRunLogs(of: node, in: records, beside: log),
            directory: snapshot ?? (FileManager.default.fileExists(atPath: worktree.path) ? worktree : nil), log: log)
        var diagnosis: Diagnosis?
        var failure: String?
        do {
            diagnosis = try await diagnoser.diagnose(request)
        } catch {
            failure = "\(error)".split(separator: "\n", maxSplits: 1).first.map { String($0.prefix(300)) } ?? "\(error)"
        }
        if let snapshot { await workspace.removeSnapshot(snapshot) }
        // Written directly: a stopped task's writes are refused, and an open run would be escalated again. Stopped
        // by a person, it isn't started again; interrupted by closing the window or quitting, the node still needs
        // its diagnosis.
        let stoppedBy = stopReasons[run]
        let interrupted = Task.isCancelled && stoppedBy == nil
        var kinds: [EventKind] = [.runFinished(run: run, outcome: diagnosis != nil ? "diagnosed" :
                                                Task.isCancelled ? stoppedBy ?? "stopped" : "failed: \(failure ?? "")")]
        if !interrupted {
            kinds.append(.diagnosisRecorded(run: run, diagnosis: diagnosis ?? Diagnosis(
                cause: "The diagnoser couldn't finish: \(stoppedBy ?? failure ?? "unknown error")",
                nextStep: "Read the escalation above and the agents' logs.")))
        }
        try await ledger.append(kinds.map { LedgerEvent(node: node.id, by: author, kind: $0) })
        guard let diagnosis else { return "\(node.displayName) diagnosis failed" }
        await tracker.comment(on: node.ticket, "🩺 Diagnosis (by an agent, from the history and logs; nothing was changed)\n"
            + "Likely cause: \(diagnosis.cause)\nSuggested next step: \(diagnosis.nextStep)")
        return "\(node.displayName) diagnosed"
    }

    /// The logs of the node's last few agent runs that still exist, oldest first.
    private func recentRunLogs(of node: NodeState, in records: [RecordedEvent], beside log: URL?) -> [URL] {
        guard let folder = log?.deletingLastPathComponent() else { return [] }
        let runs = records.compactMap { record -> RunID? in
            guard case .runStarted(let run, let role) = record.event.kind, role != .diagnoser else { return nil }
            return run
        }
        return runs.map { folder.appending(path: AgentLog.fileName(node: node.id, run: $0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .suffix(Self.diagnosisLogLimit)
    }
}
