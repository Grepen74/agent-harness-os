import Foundation

public struct RoundReport: Sendable {
    public var actions: [String] = []
    /// Set when the reconciler refused to act (e.g. the ledger failed its integrity check).
    public var safeStop: String?
    public var hasRunningAgents = false
    public var isIdle: Bool { actions.isEmpty && !hasRunningAgents }

    public init(actions: [String] = [], safeStop: String? = nil, hasRunningAgents: Bool = false) {
        self.actions = actions
        self.safeStop = safeStop
        self.hasRunningAgents = hasRunningAgents
    }
}

/// The harness loop (doc 07). Each round: look at what should be true and what is proven, take the
/// next small step per node, record it. No AI in here: every decision is a plain, testable rule.
///
/// Simplifications vs. production (doc 07):
/// - Up to `policy.maxParallelAgents` nodes take their step at the same time, each on its own branch and
///   working copy; landing is one at a time. Production hands steps to agents on many machines.
/// - It runs when asked (Step / Run in the app); production is an always-on service woken by events
///   plus a regular full check, with one leader per system and fencing tokens.
/// - Claims don't time out while running; after a restart, unfinished runs are treated as expired.
public actor Reconciler {
    let ledger: Ledger
    let tracker: any TrackerAdapter
    let external: any ExternalDependencySource
    let workspace: any Workspace
    let artifacts: any ArtifactStore
    let checks: any CheckRunner
    let acceptanceTestPreflight: any AcceptanceTestPreflight
    public nonisolated let policy: Policy
    public private(set) var team: AgentTeam
    /// Watched intervals, including finished intervals still needed by an overlapping watch.
    var agentRuns: [RunID: AgentRunSpan] = [:]
    var clock = 0
    var tasks: [NodeID: Task<String?, Never>] = [:]
    /// Nodes with a step reserved or running, including steps that haven't recorded their claim yet.
    public var busyNodes: Set<NodeID> { Set(tasks.keys) }
    private var completedActions: [String] = []
    var ownedRuns: [NodeID: RunID] = [:]
    private var stopReasons: [RunID: String] = [:]
    private var shutdownReason: String?
    private var lifecycleFailure: String?
    /// Set while a round works through the landing queue; another round meanwhile skips landing.
    private var isLanding = false
    /// Awaited after a node step is reserved and before it runs or records its claim (a test seam).
    private let beforeStep: (@Sendable (NodeID) async -> Void)?

    public init(ledger: Ledger, tracker: any TrackerAdapter, external: any ExternalDependencySource,
                workspace: any Workspace, artifacts: any ArtifactStore, checks: any CheckRunner, team: AgentTeam,
                policy: Policy = Policy(),
                acceptanceTestPreflight: any AcceptanceTestPreflight = SkippedAcceptanceTestPreflight(),
                beforeStep: (@Sendable (NodeID) async -> Void)? = nil) {
        self.beforeStep = beforeStep
        self.ledger = ledger
        self.artifacts = artifacts
        self.tracker = tracker
        self.external = external
        self.workspace = workspace
        self.checks = checks
        self.acceptanceTestPreflight = acceptanceTestPreflight
        self.team = team
        self.policy = policy
    }

    public func setTeam(_ team: AgentTeam) { self.team = team }

    /// Stops only this exact claim, and returns after its task and process cleanup have finished.
    public func stopRun(_ run: RunID, by person: String) async throws {
        guard let node = await ledger.workingState().running.first(where: { $0.activeRun?.run == run }),
              ownedRuns[node.id] == run, let task = tasks[node.id] else { return }
        if stopReasons[run] == nil { stopReasons[run] = "stopped by \(person)" }
        task.cancel()
        _ = await task.value
        if await ledger.workingState().nodes[node.id]?.activeRun?.run == run {
            throw AgentFailure(lifecycleFailure ?? "Couldn't record the stop of \(run)")
        }
    }

    /// Prevents new work and drains every owned task, including its durable finish.
    public func shutdown(reason: String) async {
        if shutdownReason == nil { shutdownReason = reason }
        let pending = Array(tasks.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.value }
    }

    // MARK: The loop

    /// One round that doesn't wait for the node steps it starts: they keep running across rounds, and each
    /// finished step's action is reported once, by the next round to return.
    public func runRound() async -> RoundReport {
        await runRound(waitForAgents: false)
    }

    /// With waiting, the round first waits for steps from earlier rounds, then for every step it starts
    /// (the simulator's Step and tests that expect each round to finish its work).
    public func runRound(waitForAgents: Bool) async -> RoundReport {
        var report = RoundReport()
        guard shutdownReason == nil, !Task.isCancelled else { return finish(report) }
        let chain = await ledger.verifyIncrementally()
        if let problem = chain.problem {
            report.safeStop = "Ledger integrity check failed at #\(problem.position): \(problem.reason). " +
                "Safe stop: nothing will happen until a human investigates."
            return finish(report)
        }
        do { try await workspace.prepare() } catch {
            report.safeStop = "Workspace repository unavailable: \(error)"
            return finish(report)
        }
        guard shutdownReason == nil, !Task.isCancelled else { return finish(report) }

        await intakeSignals(&report)
        await intakeExternal(&report)

        if waitForAgents {
            await self.waitForAgents()
            await advanceAll(&report)
        } else {
            scheduleAvailableSteps(in: await ledger.workingState())
        }

        // The landing queue: the only place where work happens strictly one at a time (doc 08 §4). A round that
        // starts while another is landing leaves the queue to it. A landing takes one of the `maxParallelAgents`
        // slots (its checks and review run agents), which scheduling keeps free for it; once it's done, the round
        // fills that slot. A node with a step reserved or running isn't landed.
        if !isLanding {
            isLanding = true
            for node in await ledger.workingState().landingQueue {
                guard shutdownReason == nil, !Task.isCancelled,
                      tasks.count < max(1, policy.maxParallelAgents) else { break }
                if let action = await step(node.id, landing: true) { report.actions.append(action) }
            }
            isLanding = false
            if !waitForAgents { scheduleAvailableSteps(in: await ledger.workingState()) }
        }

        await projectStatuses()
        return finish(report)
    }

    /// Every return path reports the steps that finished since the last report, once.
    private func finish(_ report: RoundReport) -> RoundReport {
        var report = report
        report.actions += completedActions
        completedActions.removeAll()
        report.hasRunningAgents = !tasks.isEmpty
        if report.safeStop == nil { report.safeStop = lifecycleFailure }
        return report
    }

    /// Drains owned steps through their final fingerprint comparisons and durable effects.
    /// Waiting never schedules another step, and leaves finished steps' actions for the next round's report.
    public func waitForAgents() async {
        while !tasks.isEmpty {
            let pending = Array(tasks.values)
            for task in pending { _ = await task.value }
        }
    }

    /// Like `waitForAgents()`, for the given nodes' steps only.
    public func waitForAgents(for nodes: Set<NodeID>) async {
        while let task = tasks.first(where: { nodes.contains($0.key) })?.value {
            _ = await task.value
        }
    }

    /// After a restart: runs that were started but never finished are treated as expired claims.
    public func recoverAfterRestart() async -> [String] {
        var notes: [String] = []
        for node in await ledger.workingState().nodes.values {
            guard let active = node.activeRun else { continue }
            var kinds: [EventKind] = [.runFinished(run: active.run, outcome: "abandoned: claim expired (harness restarted)")]
            switch node.phase {
            case .building: kinds.append(.phaseChanged(to: .ready))
            case .landing: try? await workspace.abortRebase(workspace.worktree(for: node.id)) // may have died mid-rebase
            default: break
            }
            try? await write(node.id, by: .reconciler, kinds)
            notes.append("Reclaimed \(node.displayName) from \(active.run)")
        }
        return notes
    }

    // MARK: Controllers: one step per node per round

    /// One step per node, up to `maxParallelAgents` nodes at a time. The steps interleave only while they wait
    /// (for an agent, a check, git): each node has its own branch and working copy, and every claim is a
    /// compare-and-swap on the node's version. Actions are reported in node order, whatever finished first.
    private func advanceAll(_ report: inout RoundReport) async {
        let state = await ledger.workingState()
        let order = state.creationOrder.filter { id in
            guard let parent = state.nodes[id]?.spec.parent else { return true }
            return state.nodes[parent]?.phase == .split
        }
        let limit = max(1, policy.maxParallelAgents)
        var actions: [Int: String] = [:]
        await withTaskGroup(of: (Int, String?).self) { group in
            var running = 0
            for (index, id) in order.enumerated() {
                if running == limit, let (finished, action) = await group.next() {
                    running -= 1
                    if let action { actions[finished] = action }
                }
                group.addTask { (index, await self.step(id)) }
                running += 1
            }
            for await (finished, action) in group {
                if let action { actions[finished] = action }
            }
        }
        report.actions += actions.keys.sorted().compactMap { actions[$0] }
    }

    /// Fills free slots in creation order. Slots count steps from earlier rounds that are still running, and
    /// steps reserved but not yet claimed, so a node never gets a second step. While a node waits to land and
    /// no landing is under way, one slot stays free for it, so new work can't starve the landing queue.
    private func scheduleAvailableSteps(in state: WorkingState) {
        let waitingToLand = !isLanding && state.landingQueue.contains { tasks[$0.id] == nil && !$0.awaitingHumanReview }
        let limit = max(1, policy.maxParallelAgents) - (waitingToLand ? 1 : 0)
        for id in state.creationOrder {
            guard shutdownReason == nil, !Task.isCancelled, tasks.count < limit else { break }
            guard tasks[id] == nil, let node = state.nodes[id], canAdvance(node, in: state) else { continue }
            startStep(id, reportCompletion: true)
        }
    }

    @discardableResult
    private func startStep(_ id: NodeID, landing: Bool = false,
                           reportCompletion: Bool = false) -> Task<String?, Never> {
        let task = Task {
            if !landing, let beforeStep = self.beforeStep { await beforeStep(id) }
            let result = await self.performStep(id, landing: landing)
            if reportCompletion, let result { self.completedActions.append(result) }
            self.tasks[id] = nil
            return result
        }
        tasks[id] = task
        return task
    }

    private func step(_ id: NodeID, landing: Bool = false) async -> String? {
        guard shutdownReason == nil, !Task.isCancelled, tasks[id] == nil else { return nil }
        return await startStep(id, landing: landing).value
    }

    private func performStep(_ id: NodeID, landing: Bool) async -> String? {
        // A reserved step that hasn't claimed anything yet simply doesn't start once stopping has begun.
        guard shutdownReason == nil, !Task.isCancelled else { return nil }
        let state = await ledger.workingState()
        guard let node = state.nodes[id] else { return nil }
        var result: String?
        var failure: String?
        do {
            try Task.checkCancellation()
            guard shutdownReason == nil else { return nil }
            if landing {
                guard node.phase == .landing, node.activeRun == nil, node.flags[.escalated] == nil,
                      !node.awaitingHumanReview else { return nil }
                result = try await land(node)
            } else {
                result = try await advance(node, in: state)
            }
        } catch LedgerError.conflict {
            failure = "ledger changed during the run"
        } catch {
            failure = "\(error)"
            result = "⚠️ \(node.displayName): \(error)"
        }
        // This is the single safety net for every post-start exit, including workspace failures.
        // Write directly: the operation's task may be cancelled, but its finish must still persist.
        let ownedRun = ownedRuns[id]
        defer {
            ownedRuns[id] = nil
            if let ownedRun { stopReasons[ownedRun] = nil }
        }
        if let current = await ledger.workingState().nodes[id], let active = current.activeRun, active.run == ownedRun {
            let stopped = stopReasons[active.run] ?? shutdownReason.map { "stopped: \($0)" }
                ?? (Task.isCancelled ? "stopped: task cancelled" : nil)
            let outcome = stopped ?? "failed: \(failure ?? "task ended without recording a finish")"
            let reason = "\(outcome). Check the run, then add harness:retry."
            var kinds: [EventKind] = [
                .runFinished(run: active.run, outcome: outcome),
                .flagSet(.escalated, reason: reason)
            ]
            if current.phase == .building { kinds.append(.phaseChanged(to: .ready)) }
            do {
                try await ledger.append(kinds.map { LedgerEvent(node: id, by: .reconciler, kind: $0) })
                await tracker.comment(on: current.ticket, reason)
                await projectStatus(of: id)
            } catch {
                lifecycleFailure = "Couldn't finish \(active.run): \(error)"
                result = lifecycleFailure
            }
        }
        return result
    }

    private func canAdvance(_ node: NodeState, in state: WorkingState) -> Bool {
        guard node.flags[.escalated] == nil, node.flags[.needsInput] == nil, node.activeRun == nil,
              !node.ticketClosed else { return false }
        // The parent was replanned: its children wait for its new breakdown.
        if let parent = node.spec.parent.flatMap({ state.nodes[$0] }), parent.phase != .split { return false }

        switch (node.spec.kind, node.phase) {
        case (.composite, .specified):
            return state.hasGate(.breakdown, at: node.id)
        case (.composite, .split):
            let children = node.children.compactMap { state.nodes[$0] }
            return !children.isEmpty && children.allSatisfy { $0.phase == .proven }
        case (.leaf, .specified):
            return state.hasGate(.breakdown, at: node.id) || state.hasGate(.build, at: node.id)
        case (.leaf, .ready):
            return state.hasGate(.build, at: node.id) &&
                (node.flags[.blocked] == nil || unresolvedDependencies(of: node, in: state).isEmpty)
        case (.leaf, .checking):
            return true
        default:
            return false
        }
    }

    private func advance(_ node: NodeState, in state: WorkingState) async throws -> String? {
        guard canAdvance(node, in: state) else { return nil }

        switch (node.spec.kind, node.phase) {
        case (.composite, .specified):
            return try await breakDown(node, in: state)

        case (.composite, .split):
            // Up the V: every child has landed with all tests passing on main, so the whole is proven.
            try await write(node.id, by: .reconciler, [.phaseChanged(to: .proven)], expecting: node.version)
            await tracker.comment(on: node.ticket, "✅ Proven: every child has landed with all tests passing on main.")
            return "\(node.displayName) proven (all children proven)"

        case (.leaf, .specified):
            return try await authorTests(node)

        case (.leaf, .ready):
            let missing = unresolvedDependencies(of: node, in: state)
            guard missing.isEmpty else {
                guard node.flags[.blocked] == nil else { return nil }
                let reason = "Waiting for \(missing.joined(separator: ", "))"
                try await write(node.id, by: .reconciler, [.flagSet(.blocked, reason: reason)], expecting: node.version)
                await tracker.comment(on: node.ticket, "⏸ Blocked: \(reason).")
                return "\(node.displayName) blocked"
            }
            return try await build(node)

        case (.leaf, .checking):
            return try await preCheck(node)

        default:
            return nil // `landing` is handled by the landing queue.
        }
    }

}
