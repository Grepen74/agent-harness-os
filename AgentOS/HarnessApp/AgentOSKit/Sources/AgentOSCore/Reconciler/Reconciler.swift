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
    private var agentRuns: [RunID: AgentRunSpan] = [:]
    private var clock = 0
    private var tasks: [NodeID: Task<String?, Never>] = [:]
    /// Nodes with a step reserved or running, including steps that haven't recorded their claim yet.
    public var busyNodes: Set<NodeID> { Set(tasks.keys) }
    private var completedActions: [String] = []
    private var ownedRuns: [NodeID: RunID] = [:]
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
        let chain = await ledger.verifyChain()
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

    // MARK: Intake: signals from people, news from other systems

    private struct Rejection: Error { let reason: String }

    private func intakeSignals(_ report: inout RoundReport) async {
        for signal in await tracker.pendingSignals() {
            let node = await ledger.workingState().node(forTicket: signal.ticket)
            do {
                guard case .human(let person) = signal.setBy else {
                    throw Rejection(reason: "Only humans can request harness work; this label was set by \(signal.setBy.label).")
                }
                let reply = try await handle(signal, from: person)
                try await write(node?.id, by: .human(person), [
                    .signalAccepted(ticket: signal.ticket, command: signal.command, reply: reply)])
                await tracker.consume(signal, reply: "✅ \(signal.command.label): \(reply)")
                report.actions.append("\(signal.ticket): \(signal.command.label) accepted")
            } catch let rejection as Rejection {
                try? await write(node?.id, by: .reconciler, [
                    .signalRejected(ticket: signal.ticket, command: signal.command, reason: rejection.reason)])
                let state = await ledger.workingState()
                let steps = Self.nextSteps(for: signal.ticket, in: state, allowed: policy.allowedSignals)
                await tracker.consume(signal, reply: "❌ \(signal.command.label): \(rejection.reason)" + Self.whatYouCanDo(steps))
                report.actions.append("\(signal.ticket): \(signal.command.label) rejected")
            } catch {
                report.actions.append("⚠️ \(signal.ticket): \(error)")
            }
        }
    }

    private func handle(_ signal: Signal, from person: String) async throws -> String {
        guard policy.allowedSignals.contains(signal.command) else {
            let allowed = HarnessCommand.allCases.filter(policy.allowedSignals.contains).map(\.label)
            throw Rejection(reason: "\(signal.command.label) isn't enabled here. Available: \(allowed.joined(separator: ", ")).")
        }
        guard let ticket = await tracker.ticket(signal.ticket) else { throw Rejection(reason: "Ticket not found.") }
        let state = await ledger.workingState()
        let node = state.node(forTicket: ticket.key)
        if let replanned = state.superseded[ticket.key], node == nil {
            throw Rejection(reason: "Superseded: \(replanned) was replanned and this ticket is no longer part of it.")
        }
        // These can discard or rewrite a working copy, so not while a step is reserved or running below the
        // node, including one that hasn't recorded its claim yet.
        if [.retry, .retest, .replan].contains(signal.command), let node,
           let busy = state.subtree(of: node.id).first(where: { tasks[$0.id] != nil || $0.activeRun != nil }) {
            throw Rejection(reason: "An agent is working on \(workLink(busy)) right now. Wait for it to finish, " +
                "then add \(signal.command.label) again if it's still needed.")
        }

        switch signal.command {
        case .preview:
            // A preview does NOT adopt the ticket and creates nothing (doc 05 §3).
            let problems = policy.readinessProblems(ticket)
            guard problems.isEmpty else { throw Rejection(reason: "Not ready yet. Missing: \(problems.joined(separator: ", ")).") }
            let spec = Planner.rootSpec(for: ticket)
            let answers = try (node?.clarifications ?? []) + Self.newPreviewAnswers(on: ticket, for: node)
            let breakdown = try await propose(spec, ticketKey: ticket.key, clarifications: answers, log: nil)
            let questions = policy.questions(in: breakdown.report, role: .decomposer)
            guard questions.isEmpty else {
                // Nothing is recorded: answers in comments below this are read by the next preview, and kept
                // once the ticket is adopted (breakdown or go).
                await tracker.comment(on: ticket.key, """
                    \(Self.previewQuestionsMarker):
                    \(Self.numbered(questions))
                    \(Self.questionReplyInstructions(for: questions, then: .preview))
                    """)
                return "questions posted above; no preview recorded"
            }
            await postProceedingOnSuggestions(breakdown.report.questions, on: ticket.key)
            let children = Planner.childSpecs(parent: spec, proposals: breakdown.children)
            let number = (state.previews[ticket.key]?.number ?? 0) + 1
            try await write(nil, by: .reconciler, [
                .previewRecorded(ticket: ticket.key, number: number, specHash: spec.specHash, proposal: children)])
            // Accepting the preview accepts its assumptions too: they aren't asked about again.
            await tracker.comment(on: ticket.key, """
                🔍 Preview #\(number). Nothing has been created.
                \(Planner.describe(children, under: ticket.title))\(Self.assumptionsNote("Assumptions the decomposer made", policy.assumptions(in: breakdown.report)))
                Accept with label harness:breakdown, or edit the ticket and preview again.
                """)
            return "preview #\(number) posted above"

        case .breakdown:
            if let node {
                guard node.spec.kind == .composite else {
                    throw Rejection(reason: "\(node.spec.id) is a leaf: small enough to build as it is, so there is nothing " +
                        "to break down. If it turns out too big, that's a spec change and its parent re-plans (doc 02 §8–9; not in this mock).")
                }
                guard !node.gates.contains(.breakdown) else { throw Rejection(reason: "Breakdown is already approved.") }
                try await write(node.id, by: .human(person), [.gateOpened(.breakdown)] + Self.answerEvents(on: ticket, for: node))
                return "breakdown approved"
            }
            let problems = policy.readinessProblems(ticket)
            guard problems.isEmpty else { throw Rejection(reason: "Not ready yet. Missing: \(problems.joined(separator: ", ")).") }
            let spec = Planner.rootSpec(for: ticket)
            // Adoption: from now on the harness owns the node; the ticket shows a projection of it.
            try await write(spec.id, by: .human(person), [.nodeCreated(spec: spec, ticket: ticket.key), .gateOpened(.breakdown)]
                + Self.answerEvents(on: ticket, for: nil))
            let preview = state.previews[ticket.key].flatMap { $0.specHash == spec.specHash ? $0 : nil }
            return "adopted; breakdown approved" +
                (preview.map { " (will create exactly preview #\($0.number))" } ?? "") + "\n" + spec.trackerSummary

        case .build:
            guard let node else { throw Rejection(reason: "Not adopted yet. Approve a breakdown first (harness:breakdown).") }
            guard node.phase != .specified || node.spec.kind != .composite else {
                throw Rejection(reason: "The breakdown isn't finished yet. Try again when the child tickets exist.")
            }
            let reviews = waitingForReview(under: node.id, in: state)
            guard !node.gates.contains(.build) || !reviews.isEmpty else { throw Rejection(reason: "Build is already approved.") }
            if !node.gates.contains(.build) { try await write(node.id, by: .human(person), [.gateOpened(.build)]) }
            return "build approved for \(node.spec.id) and everything below it" + (try await approve(reviews, by: person))

        case .retry:
            if let node, node.flags[.needsInput] != nil {
                return try await resume(node, answeredOn: ticket, by: person)
            }
            // A stopped node with old suggestions is retried as usual unless the person corrects one by number.
            if let node, !node.suggestedAnswers.isEmpty,
               node.flags[.escalated] == nil || Self.latestCorrectionComment(on: ticket, for: node) != nil {
                return try await correctSuggestion(on: node, ticket: ticket, in: state)
            }
            if let node, node.flags[.escalated] == nil, let comment = ticket.comments.last, comment.author.isHuman,
               Self.corrections(in: comment.text) != nil {
                return try await correctSuggestion(on: node, ticket: ticket, in: state)
            }
            guard let node, node.flags[.escalated] != nil else {
                throw Rejection(reason: "Nothing to retry. \(HarnessCommand.retry.label) only continues work that stopped: " +
                    "an escalation, or questions or a review waiting for you.")
            }
            try await write(node.id, by: .human(person), [.flagCleared(.escalated), .attemptsReset])
            return "escalation cleared; attempts reset"

        case .retest:
            return try await retest(node, ticket: ticket, by: person)

        case .replan:
            return try await replan(node, ticket: ticket, by: person)

        case .go:
            // Both gates at once: the readiness checks for both run now, so nothing stops halfway for lack
            // of permission. Production: also checks the build budget is set (doc 05 §5).
            if let node {
                let missing = [Gate.breakdown, .build].filter { !node.gates.contains($0) }
                let reviews = waitingForReview(under: node.id, in: state).filter { !$0.awaitingHumanReview }
                guard !missing.isEmpty || !reviews.isEmpty else { throw Rejection(reason: "Breakdown and build are already approved.") }
                if !missing.isEmpty {
                    try await write(node.id, by: .human(person), missing.map { .gateOpened($0) } + Self.answerEvents(on: ticket, for: node))
                }
                let approved = missing.isEmpty ? "build" : missing.map(\.rawValue).joined(separator: " and ")
                return "\(approved) approved for \(node.spec.id) and everything below it" + (try await approve(reviews, by: person))
            }
            let problems = policy.readinessProblems(ticket)
            guard problems.isEmpty else { throw Rejection(reason: "Not ready yet. Missing: \(problems.joined(separator: ", ")).") }
            let spec = Planner.rootSpec(for: ticket)
            try await write(spec.id, by: .human(person), [
                .nodeCreated(spec: spec, ticket: ticket.key), .gateOpened(.breakdown), .gateOpened(.build)]
                + Self.answerEvents(on: ticket, for: nil))
            return "adopted; breakdown and build approved: it will be broken down, built and checked without stopping\n"
                + spec.trackerSummary
        }
    }

    /// Corrections by number, one per line: `2: answer`, `2. answer` or `2. Answer: answer` (the form question
    /// comments suggest). Nil when the text isn't a numbered reply at all.
    static func corrections(in text: String) -> [(number: Int, answer: String)]? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let parsed = lines.map { line -> (Int, String)? in
            guard let match = line.firstMatch(of: /^(\d+)\s*[:.)]\s*(?:[Aa]nswer\s*:)?(.*)$/), let number = Int(match.1) else {
                return nil
            }
            return (number, String(match.2).trimmingCharacters(in: .whitespaces))
        }
        guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else { return nil }
        return parsed.compactMap { $0 }
    }

    /// The latest human comment since the newest suggestions, when it's a numbered correction.
    private static func latestCorrectionComment(on ticket: Ticket, for node: NodeState) -> Comment? {
        guard let newest = node.suggestedAnswers.values.map(\.reportedAt).max(),
              let comment = ticket.comments.last(where: { $0.author.isHuman && $0.at >= newest }),
              corrections(in: comment.text) != nil else { return nil }
        return comment
    }

    private func correctSuggestion(on node: NodeState, ticket: Ticket, in state: WorkingState) async throws -> String {
        let guidance = "To correct a suggested answer, comment with its number from the latest " +
            "\"Proceeding on suggested answers\" list, one per line, e.g. `2: <correct answer>`, then add harness:retry. " +
            "If the work stopped for another reason, comment what to change without numbers and add harness:retry."
        guard let (role, suggestions) = node.suggestedAnswers.max(by: { $0.value.reportedAt < $1.value.reportedAt }),
              let comment = ticket.comments.last(where: { $0.author.isHuman && $0.at >= suggestions.reportedAt }),
              let corrections = Self.corrections(in: comment.text),
              corrections.allSatisfy({ $0.number > 0 && $0.number <= suggestions.questions.count && !$0.answer.isEmpty })
        else {
            throw Rejection(reason: guidance)
        }
        if role == .decomposer, let started = state.subtree(of: node.id).first(where: Self.hasStartedBuilding) {
            throw Rejection(reason: "Building has started on \(workLink(started)), so this breakdown cannot be corrected. " +
                "Open a follow-up ticket for the corrected work.")
        }
        if role == .testAuthor, node.landedCommit != nil || node.phase == .proven {
            throw Rejection(reason: "\(workLink(node)) has already landed and cannot be changed. " +
                "Open a follow-up ticket for the corrected work.")
        }
        guard node.activeRun == nil else {
            throw Rejection(reason: "An agent is still running on \(workLink(node)). Wait for it to finish, then add harness:retry.")
        }
        if role == .testAuthor { try await workspace.removeWorktree(for: node.id) }
        var spec = node.spec
        if role == .decomposer { spec.kind = .composite }
        // Replanning preserves clarifications and children; restore only gates the person already approved.
        let kinds: [EventKind] = corrections.map {
            .questionsAnswered(Clarification(questions: [suggestions.questions[$0.number - 1].question], answer: $0.answer))
        } + [.replanned(spec: spec)] + Gate.allCases.filter(node.gates.contains).map { .gateOpened($0) }
        try await write(node.id, by: comment.author, kinds, expecting: node.version)
        return role == .decomposer
            ? "correction recorded; decomposition will rerun, retaining unchanged children and their tests and approvals"
            : "correction recorded; the old working copy was discarded and test authoring will restart from the latest landing branch"
    }

    private func workLink(_ node: NodeState) -> String {
        if node.ticket.hasPrefix("GH-"), let number = Int(node.ticket.dropFirst(3)),
           !tracker.contextRepository.isEmpty {
            return "[\(node.displayName)](https://github.com/\(tracker.contextRepository)/issues/\(number))"
        }
        return "[\(node.displayName)](\(workspace.worktree(for: node.id).absoluteString))"
    }

    /// Discards an obsolete leaf worktree and starts test authoring again from the latest landing branch.
    private func retest(_ node: NodeState?, ticket: Ticket, by person: String) async throws -> String {
        guard let node else {
            throw Rejection(reason: "Not adopted yet, so there are no acceptance tests to rewrite.")
        }
        guard node.landedCommit == nil else {
            throw Rejection(reason: "\(node.spec.id) has already landed, so its acceptance tests cannot be replaced.")
        }
        guard node.spec.kind == .leaf,
              node.flags[.escalated] != nil || node.flags[.needsInput] != nil else {
            throw Rejection(reason: "Nothing to retest. \(HarnessCommand.retest.label) only rewrites acceptance tests " +
                "for a leaf that is escalated or waiting for input.")
        }

        try await workspace.removeWorktree(for: node.id)
        var kinds: [EventKind] = []
        if let feedback = Self.answer(on: ticket) {
            kinds.append(.questionsAnswered(Clarification(
                questions: ["Feedback for rewriting the acceptance tests"],
                answer: feedback
            )))
        }
        if node.flags[.needsInput] != nil { kinds.append(.flagCleared(.needsInput)) }
        if node.flags[.escalated] != nil { kinds.append(.flagCleared(.escalated)) }
        kinds.append(.phaseChanged(to: .specified))
        try await write(node.id, by: .human(person), kinds)
        return "current working copy and tests discarded; the test author will rewrite them from the latest landing branch"
    }

    /// `harness:replan`: the ticket changed (criteria, a forgotten "Blocked by", a breakdown that missed the point).
    /// Only before anything below it is built: replanning then costs no work that can't simply be redone. The node
    /// takes the ticket as it is now and starts over as just adopted, without gates, so people choose again how
    /// far it goes (preview, breakdown or go). The children wait for that breakdown, which keeps the unchanged ones.
    private func replan(_ node: NodeState?, ticket: Ticket, by person: String) async throws -> String {
        let state = await ledger.workingState()
        guard let node else {
            throw Rejection(reason: "Not adopted yet, so there's no plan to redo. Edit the ticket and preview it again.")
        }
        if let parent = node.spec.parent.flatMap({ state.nodes[$0] }) {
            throw Rejection(reason: "\(ticket.key) is part of \(parent.displayName)'s breakdown. Replan \(parent.displayName) instead, " +
                "or comment here and add \(HarnessCommand.retry.label) when it's waiting for you.")
        }
        let subtree = state.subtree(of: node.id)
        if let started = subtree.first(where: Self.hasStartedBuilding) {
            throw Rejection(reason: "Building has started on \(started.ticket) (\(started.phase.rawValue)), so replanning " +
                "would throw away built work. Changing a spec once building has started isn't supported yet.")
        }
        let problems = policy.readinessProblems(ticket)
        guard problems.isEmpty else { throw Rejection(reason: "Not ready yet. Missing: \(problems.joined(separator: ", ")).") }

        let spec = Planner.rootSpec(for: ticket)
        if node.spec.kind == .leaf { try? await workspace.removeWorktree(for: node.id) }
        try await write(node.id, by: .human(person), [.replanned(spec: spec)])
        let children = node.children.compactMap { state.nodes[$0]?.ticket }
        let closed = children.isEmpty ? "" : "\nIts child tickets (\(children.joined(separator: ", "))) are paused. The next " +
            "breakdown keeps those it still contains unchanged, with their tests and approvals, and closes the others."
        let replanned = await ledger.workingState()
        let missing = replanned.nodes[node.id].map { unresolvedDependencies(of: $0, in: replanned) } ?? spec.dependsOn
        let waits = missing.isEmpty ? "" : "\nWaits for: \(missing.joined(separator: ", "))."
        return "replanned from the ticket as it is now; nothing is approved yet.\(closed)\(waits)\n" +
            "Next: \(HarnessCommand.preview.label) to see the new breakdown first, \(HarnessCommand.breakdown.label) " +
            "to break it down, or \(HarnessCommand.go.label) to break it down and build it."
    }

    /// Past the point where replanning is free: an agent working on it, or code written, checked or landed.
    static func hasStartedBuilding(_ node: NodeState) -> Bool {
        node.activeRun != nil || node.lastSubmission != nil || node.landedCommit != nil
            || [.building, .checking, .landing, .proven].contains(node.phase)
    }

    /// `harness:retry` on a node waiting for input: the human comments since the harness asked are the answer.
    /// Without open questions it was waiting for a review of its tests, so the answer is feedback on them and
    /// the tests are written again with it.
    private func resume(_ node: NodeState, answeredOn ticket: Ticket, by person: String) async throws -> String {
        if await isWaitingOnOtherTest(node) {
            // The person may have fixed the other test instead of answering; the implementer tries again either way.
            var kinds: [EventKind] = [.flagCleared(.needsInput)]
            if let answer = Self.answer(on: ticket) {
                kinds.insert(.questionsAnswered(Clarification(questions: ["How to proceed with the conflicting test"], answer: answer)), at: 0)
            }
            if node.flags[.escalated] != nil { kinds += [.flagCleared(.escalated), .attemptsReset] }
            // Pick up a fix to the other test made since; the implementation was already discarded, the tests are kept.
            let directory = workspace.worktree(for: node.id)
            _ = try await workspace.rebaseOntoMain(directory)
            try await write(node.id, by: .human(person), kinds)
            return "the implementer will try again on the latest landing branch"
        }
        if await isDisputingReviewFindings(node) {
            guard let answer = Self.answer(on: ticket) else {
                throw Rejection(reason: "Comment how to proceed with the review findings first, then add harness:retry " +
                    "again. If they are about the acceptance tests, add harness:retest instead.")
            }
            var kinds: [EventKind] = [
                .questionsAnswered(Clarification(questions: ["How to proceed with the change review's findings"], answer: answer)),
                .flagCleared(.needsInput)]
            if node.flags[.escalated] != nil { kinds += [.flagCleared(.escalated), .attemptsReset] }
            try await write(node.id, by: .human(person), kinds)
            return "answer recorded; the implementer will try again with it"
        }
        guard let answer = Self.answer(on: ticket) else {
            // Stopped by the acceptance-test compile check (tests not yet accepted): the person may have fixed the
            // tests or the harness, so the test author runs again without needing a comment.
            if node.openQuestions.isEmpty && node.spec.kind == .leaf && node.phase == .specified {
                var kinds: [EventKind] = [.flagCleared(.needsInput)]
                if node.flags[.escalated] != nil { kinds += [.flagCleared(.escalated), .attemptsReset] }
                try await write(node.id, by: .human(person), kinds)
                return "the test author will write the acceptance tests again"
            }
            throw Rejection(reason: "Answer \(node.openQuestions.isEmpty ? "the review request" : "the questions") above in a comment " +
                "first, then add harness:retry again. To build the tests as they are, add harness:build instead.")
        }
        let isReview = node.openQuestions.isEmpty
        let answers = try isReview
            ? [Clarification(questions: ["Feedback on the acceptance tests"], answer: answer)]
            : Self.resolveAnswers(answer, to: node.openQuestions, signal: .retry)
        var kinds: [EventKind] = answers.map { .questionsAnswered($0) } + [.flagCleared(.needsInput)]
        if isReview && node.spec.kind == .leaf && node.phase == .ready {
            try? await workspace.removeWorktree(for: node.id)
            kinds.append(.phaseChanged(to: .specified))
        }
        if node.flags[.escalated] != nil { kinds += [.flagCleared(.escalated), .attemptsReset] }
        try await write(node.id, by: .human(person), kinds)
        return isReview ? "feedback recorded; the acceptance tests will be written again with it" : "answer recorded; work continues with it"
    }

    /// Whether the node waits because a test of other work conflicts with it: the latest "Needs input" came with
    /// a broken-test report (same run, nothing started in between) naming a test that isn't the node's own.
    private func isWaitingOnOtherTest(_ node: NodeState) async -> Bool {
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

    /// Whether the node waits because its implementer made no changes for the change review's findings.
    private func isDisputingReviewFindings(_ node: NodeState) async -> Bool {
        guard node.flags[.needsInput] != nil else { return false }
        let records = await ledger.allRecords().filter { $0.event.node == node.id }
        guard let flag = records.last(where: {
            if case .flagSet(.needsInput, _) = $0.event.kind { return true }
            return false
        }) else { return false }
        for record in records.reversed() where record.position < flag.position {
            switch record.event.kind {
            case .runFinished(_, let outcome): return outcome == Self.unaddressedFindingsOutcome
            case .runStarted: return false
            default: continue
            }
        }
        return false
    }

    static let unaddressedFindingsOutcome = "made no changes for the review findings"

    /// Human comments after the harness's latest "Needs input" comment, or nil when nobody answered yet.
    static func answer(on ticket: Ticket) -> String? {
        guard let asked = ticket.comments.lastIndex(where: { !$0.author.isHuman && $0.text.contains(needsInputMarker) }) else { return nil }
        let replies = ticket.comments[(asked + 1)...].filter(\.author.isHuman).map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return replies.isEmpty ? nil : replies.joined(separator: "\n\n")
    }

    static let needsInputMarker = "❓ Needs input"
    static let previewQuestionsMarker = "❓ The decomposer has questions before it can propose a breakdown"

    private static func resolveAnswers(
        _ reply: String, to questions: [AgentQuestion], signal: HarnessCommand
    ) throws -> [Clarification] {
        let pattern = #"(?:^|[,\r\n])\s*(\d+)\.\s*Answer:\s*"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let text = reply as NSString
        let matches = regex.matches(in: reply, range: NSRange(location: 0, length: text.length))
        let acceptsSuggestions = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "ok"
        if matches.isEmpty && !acceptsSuggestions {
            return [Clarification(questions: questions.map(\.question), answer: reply)]
        }
        var corrections: [Int: String] = [:]
        for (index, match) in matches.enumerated() {
            guard let number = Int(text.substring(with: match.range(at: 1))),
                  questions.indices.contains(number - 1) else {
                throw Rejection(reason: "A correction names an unknown question. Use the original question numbers, then add \(signal.label).")
            }
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : text.length
            let answer = text.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                throw Rejection(reason: "Question \(number) needs answer text. Reply '\(number). Answer: <answer>', then add \(signal.label).")
            }
            corrections[number] = answer
        }
        let unresolved = questions.indices.filter {
            corrections[$0 + 1] == nil && questions[$0].suggestion == nil
        }
        guard unresolved.isEmpty else {
            let numbers = unresolved.map { String($0 + 1) }.joined(separator: ", ")
            throw Rejection(reason: "Questions \(numbers) are still open. Reply with the remaining original numbers as 'N. Answer: <answer>', then add \(signal.label).")
        }
        return questions.enumerated().compactMap { index, question in
            (corrections[index + 1] ?? question.suggestion).map {
                Clarification(questions: [question.question], answer: $0)
            }
        }
    }

    /// Answers to a preview's questions: the human comments after each such question comment (up to the next
    /// one), with the questions it asked. Those the node doesn't have yet.
    static func newPreviewAnswers(on ticket: Ticket, for node: NodeState?) throws -> [Clarification] {
        var answers: [Clarification] = []
        var asked: [AgentQuestion]?
        var replies: [String] = []
        func flush() throws {
            if let asked, !replies.isEmpty {
                answers += try resolveAnswers(replies.joined(separator: "\n\n"), to: asked, signal: .preview)
            }
            replies = []
        }
        for comment in ticket.comments {
            if !comment.author.isHuman && comment.text.contains(previewQuestionsMarker) {
                try flush()
                var questions: [AgentQuestion] = []
                for line in comment.text.split(separator: "\n") {
                    if let match = line.firstMatch(of: /^\d+\.\s+(.+)$/) {
                        questions.append(AgentQuestion(question: String(match.output.1)))
                    } else if let last = questions.indices.last,
                              let range = line.range(of: "   Suggested answer: ") {
                        questions[last].suggestion = String(line[range.upperBound...])
                    }
                }
                asked = questions
            } else if asked != nil, comment.author.isHuman {
                let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { replies.append(text) }
            }
        }
        try flush()
        return answers.filter { !(node?.clarifications.contains($0) ?? false) }
    }

    /// Adopting or approving keeps the answers given to previews, for every agent that works on it later.
    private static func answerEvents(on ticket: Ticket, for node: NodeState?) throws -> [EventKind] {
        try newPreviewAnswers(on: ticket, for: node).map { .questionsAnswered($0) }
    }

    /// Leaves below `id` (or `id` itself) whose acceptance tests wait for a person's review before build.
    private func waitingForReview(under id: NodeID, in state: WorkingState) -> [NodeState] {
        state.subtree(of: id).filter {
            $0.awaitingHumanReview
                || ($0.flags[.needsInput] != nil && $0.openQuestions.isEmpty && $0.phase == .ready)
        }
    }

    /// `harness:build` or `harness:go` approves the tests of the leaves waiting for review.
    private func approve(_ reviews: [NodeState], by person: String) async throws -> String {
        for node in reviews {
            if let commit = node.pendingHumanReview {
                try await write(node.id, by: .human(person), [.humanReviewApproved(commit: commit)])
            } else {
                try await write(node.id, by: .human(person), [.flagCleared(.needsInput)])
            }
        }
        return reviews.isEmpty ? "" : "; review approved for \(reviews.map(\.ticket).joined(separator: ", "))"
    }

    private func intakeExternal(_ report: inout RoundReport) async {
        let state = await ledger.workingState()
        for ref in (await external.deliveredKeys()).subtracting(state.resolvedExternal).sorted() {
            try? await write(nil, by: .adapter("external system"), [.externalDependencyResolved(ref: ref)])
            report.actions.append("\(ref) delivered by the other system")
        }
        let updated = await ledger.workingState()
        for node in updated.nodes.values where node.flags[.blocked] != nil {
            if unresolvedDependencies(of: node, in: updated).isEmpty {
                try? await write(node.id, by: .reconciler, [.flagCleared(.blocked)])
                await tracker.comment(on: node.ticket, "🔓 Unblocked: everything this waits for is done or delivered.")
                report.actions.append("\(node.displayName) unblocked")
            }
        }
        for node in updated.nodes.values {
            let closed = await tracker.isClosed(node.ticket)
            guard closed != node.ticketClosed else { continue }
            try? await write(node.id, by: .adapter("tracker"), [closed ? .ticketClosed : .ticketReopened])
            report.actions.append("\(node.displayName) \(closed ? "closed on the tracker: no more work on it" : "reopened")")
        }
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

    private func breakDown(_ node: NodeState, in state: WorkingState) async throws -> String {
        let proposed: [NodeSpec]
        let author: Participant
        var assumptions: [String] = []
        if let preview = state.previews[node.ticket], preview.specHash == node.spec.specHash {
            // What you saw is what you get: no regeneration (doc 05 §3).
            proposed = preview.proposal.map { spec in
                var child = spec
                child.parent = node.id
                return child
            }
            author = .reconciler
        } else {
            let run = Self.newRunID()
            author = .agent(run: run, role: .decomposer)
            try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .decomposer)], expecting: node.version)
            let breakdown: Breakdown
            do {
                breakdown = try await propose(
                    node.spec, ticketKey: node.ticket,
                    clarifications: state.clarifications(for: node.id), log: agentLog(node, run)
                )
                try Task.checkCancellation()
            } catch {
                try await write(node.id, by: author, [
                    .runFinished(run: run, outcome: "failed: \(error)"),
                    .flagSet(.escalated, reason: "Breakdown failed: \(error)")])
                await tracker.comment(on: node.ticket, "⚠️ Needs a human: breakdown failed (\(error)). Fix the ticket, then add harness:retry.")
                return "\(node.displayName) breakdown failed → escalated"
            }
            let questions = policy.questions(in: breakdown.report, role: .decomposer)
            guard questions.isEmpty else {
                return try await raise(questions, on: node, by: author, run: run, role: .decomposer)
            }
            try await recordSuggestions(breakdown.report.questions, on: node, role: .decomposer, by: author)
            proposed = Planner.childSpecs(parent: node.spec, proposals: breakdown.children)
            assumptions = policy.assumptions(in: breakdown.report)
            try await write(node.id, by: author, [.runFinished(run: run, outcome: "proposed \(proposed.count) children")]
                + (assumptions.isEmpty ? [] : [.assumptionsReported(role: .decomposer, assumptions: assumptions)]))
        }
        let note = Self.assumptionsNote("Assumptions the decomposer made", assumptions)
        let (children, revision) = try await revise(node, proposed: proposed, in: state)

        // Leaf check (doc 02 §4): a "breakdown" into one piece is the node itself, so it becomes the leaf.
        // Production: the decomposer runs the full leaf check before proposing children at all.
        if children.count <= 1 {
            let touches = children.first?.touches ?? [ComponentName.from(node.spec.title, maxWords: 3)]
            let needs = Set(node.spec.dependsOn + (children.first?.dependsOn ?? [])).sorted()
            try await write(node.id, by: author, [.becameLeaf(touches: touches)]
                + needs.map { .linkAdded(TypedLink(from: node.id, type: .dependsOn, to: $0)) })
            await tracker.comment(on: node.ticket, """
                🍃 No breakdown needed: small enough to build as it is (leaf check passed).
                \(Planner.describe(children, under: node.spec.title))\(note)\(revision)
                This ticket gets its own branch and acceptance tests next; then add harness:build.
                """)
            return "\(node.displayName) passed the leaf check: built as one leaf"
        }

        for var spec in children {
            // Revision matches existing children independently of their ticket-derived IDs.
            if await ledger.workingState().nodes[spec.id] != nil { continue }
            let key: String
            do {
                key = try await tracker.createChildTicket(parent: node.ticket, spec: spec, by: author)
            } catch {
                try await write(node.id, by: .reconciler, [.flagSet(.escalated, reason: "Couldn't create a child ticket: \(error)")])
                return "\(node.displayName) breakdown stopped: couldn't create \"\(spec.title)\" → escalated"
            }
            if tracker.createsChildTickets {
                spec.id = "wn-\(key)"
            }
            let links = spec.dependsOn.map { TypedLink(from: spec.id, type: .dependsOn, to: $0) }
            try await write(spec.id, by: author, [.nodeCreated(spec: spec, ticket: key)] + links.map { .linkAdded($0) })
        }
        try await write(node.id, by: .reconciler, [.phaseChanged(to: .split)])
        await tracker.comment(on: node.ticket, """
            🌳 Broken down. Each leaf gets its own branch and acceptance tests next; then add harness:build.
            \(Planner.describe(children, under: node.spec.title))\(note)\(revision)
            """)
        return "\(node.displayName) broken down into \(children.count) leaves"
    }

    /// After a replan the node still has its old children. Those the new breakdown contains unchanged (same spec
    /// fingerprint) are kept, with their tickets, tests and approvals, under their own ids; the others are dropped
    /// and their tickets closed as superseded. New children get ids no kept child uses.
    /// Returns the children to create (kept ones are skipped as already present) and a note for the ticket.
    private func revise(_ node: NodeState, proposed: [NodeSpec], in state: WorkingState) async throws -> ([NodeSpec], String) {
        let old = node.children.compactMap { state.nodes[$0] }
        guard !old.isEmpty else { return (proposed, "") }
        var unmatched = old
        var specs: [NodeSpec] = []
        var kept: [NodeSpec] = []
        for spec in proposed {
            if proposed.count > 1, let match = unmatched.firstIndex(where: { $0.spec.specHash == spec.specHash }) {
                var revised = spec
                revised.id = unmatched[match].id
                kept.append(revised)
                specs.append(revised)
                unmatched.remove(at: match)
            } else {
                specs.append(spec)
            }
        }
        var used = Set(kept.map(\.id))
        var next = proposed.count + old.count
        for index in specs.indices where !kept.contains(where: { $0.id == specs[index].id }) {
            while used.contains(specs[index].id) {
                next += 1
                specs[index].id = "\(node.id).\(next)"
            }
            used.insert(specs[index].id)
        }
        for gone in unmatched { try? await workspace.removeWorktree(for: gone.id) }
        try await write(node.id, by: .reconciler, [.breakdownRevised(kept: kept, dropped: unmatched.map(\.id))])
        for gone in unmatched {
            await tracker.close(gone.ticket, saying: "🗑 Superseded: \(node.displayName) was replanned and its new breakdown doesn't contain this.")
        }
        let keptTickets = kept.compactMap { state.nodes[$0.id]?.ticket }
        var lines: [String] = []
        if !keptTickets.isEmpty { lines.append("Kept from the old breakdown, with their tests: \(keptTickets.joined(separator: ", ")).") }
        if !unmatched.isEmpty { lines.append("Closed as superseded: \(unmatched.map(\.ticket).joined(separator: ", ")).") }
        return (specs, "\n" + lines.joined(separator: "\n"))
    }

    /// Left side of the V: a fresh branch for the leaf, and its acceptance tests as the branch's first commit.
    private func authorTests(_ node: NodeState) async throws -> String {
        let run = Self.newRunID()
        let author = Participant.agent(run: run, role: .testAuthor)
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .testAuthor)], expecting: node.version)
        let directory = try await workspace.createWorktree(for: node.id)
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

        if team.reviewer != nil, policy.review.requiresReview {
            let context = try await workspace.reviewContext(in: directory, against: policy.review.baseBranch)
            if policy.review.level(for: node.spec.touches + context.changedFiles) != .none {
                let result = try await review(node, stage: .acceptanceTests, context: context, in: directory, run: run)
                if !result.passed {
                    return try await returnReviewFindings(result, stage: .acceptanceTests, node: node, run: run)
                }
            }
        }

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
        let history = await ledger.allRecords().filter { $0.event.node == node.id }
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

    /// The agent can't go on without a person: record its questions and ask on the ticket.
    private func raise(
        _ questions: [AgentQuestion],
        on node: NodeState,
        by author: Participant,
        run: RunID,
        role: AgentRole,
        additionalKinds: [EventKind] = []
    ) async throws -> String {
        let plural = questions.count == 1 ? "question" : "questions"
        try await write(node.id, by: author, [
            .runFinished(run: run, outcome: "asked \(questions.count) \(plural)"), .questionsRaised(role: role, questions: questions),
            .flagSet(.needsInput, reason: "\(questions.count) open \(plural) from the \(role.title)")
        ] + additionalKinds)
        await tracker.comment(on: node.ticket, """
            \(Self.needsInputMarker): the \(role.title) can't go on without answers.
            \(Self.numbered(questions))
            \(Self.questionReplyInstructions(for: questions, then: .retry))
            """)
        return "\(node.displayName) needs input: \(questions.count) \(plural) from the \(role.title)"
    }

    static func numbered(_ items: [AgentQuestion]) -> String {
        items.enumerated().map { index, item in
            let suggestion = item.suggestion.map { "\n   Suggested answer: \($0)" } ?? ""
            return "\(index + 1). \(item.question)\(suggestion)"
        }.joined(separator: "\n")
    }

    private static func questionReplyInstructions(for questions: [AgentQuestion], then command: HarnessCommand) -> String {
        let suggested = questions.filter { $0.suggestion != nil }.count
        if suggested == 0 {
            return "Answer them in a comment, e.g. `1. Answer: <answer text>, 2. Answer: <answer text>`. " +
                "Then add \(command.label)."
        }
        let unsuggested = suggested == questions.count ? "" :
            " Questions without a suggested answer must be answered in writing."
        return "Answer them in a comment: reply `ok` to accept all suggested answers, or use " +
            "`1. Answer: <answer text>, 2. Answer: <answer text>` to correct selected answers " +
            "while accepting the remaining suggestions.\(unsuggested) Then add \(command.label)."
    }

    private func postProceedingOnSuggestions(_ questions: [AgentQuestion], on ticket: String) async {
        guard !questions.isEmpty, questions.allSatisfy({ $0.suggestion != nil }) else { return }
        await tracker.comment(on: ticket, """
            💡 Proceeding on suggested answers:
            \(Self.numbered(questions))
            To correct one, comment with its number and the corrected answer, then add harness:retry.
            """)
    }

    private func recordSuggestions(_ questions: [AgentQuestion], on node: NodeState,
                                   role: AgentRole, by author: Participant) async throws {
        let suggestions = questions.allSatisfy { $0.suggestion != nil } ? questions : []
        try await write(node.id, by: author, [.suggestionsReported(role: role, questions: suggestions)])
        await postProceedingOnSuggestions(suggestions, on: node.ticket)
    }

    /// An empty string without assumptions; otherwise a section to append to a comment.
    static func assumptionsNote(_ heading: String, _ assumptions: [String]) -> String {
        assumptions.isEmpty ? "" : "\n📝 \(heading):\n" + assumptions.map { "- \($0)" }.joined(separator: "\n")
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

    private func build(_ node: NodeState) async throws -> String {
        let run = Self.newRunID()
        let author = Participant.agent(run: run, role: .implementer)
        // Record the claim and intent first; only then start the agent.
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .implementer), .phaseChanged(to: .building)],
                        expecting: node.version)
        let directory = workspace.worktree(for: node.id)
        do {
            try await workspace.prepareBuild(in: directory)
            let task = await makeTask(node, run: run, in: directory, log: agentLog(node, run), for: .implementer)
            let implementationResult = try await withScratchDirectory(task.scratchDirectory) {
                try await watchingUserGitState(node, run: run) {
                    try await team.implementer.implement(task)
                }
            }
            try Task.checkCancellation()
            let report = implementationResult as? AgentReport ?? AgentReport()
            let questions = policy.questions(in: report)
            guard questions.isEmpty else {
                try await workspace.resetForRework(directory)
                return try await raise(
                    questions,
                    on: node,
                    by: author,
                    run: run,
                    role: .implementer,
                    additionalKinds: [.phaseChanged(to: .ready)]
                )
            }
            await postProceedingOnSuggestions(report.questions, on: node.ticket)
            let assumptions = policy.assumptions(in: report)
            if let brokenTest = report.brokenTest {
                return try await routeBrokenTest(brokenTest, from: node, run: run, author: author, directory: directory)
            }
            guard let commit = try await workspace.commitAll(
                in: directory,
                message: "\(node.spec.id): \(node.spec.title)",
                author: run
            ) else {
                if let findings = node.latestReviewFeedback, !node.reviewFeedbackAnswered, !node.landingReworkPending {
                    return try await disputeReviewFindings(findings, on: node, run: run, author: author)
                }
                if report.alreadySatisfied && !node.landingReworkPending {
                    // The tests' own commit is the candidate; the verifier decides whether they really pass.
                    let head = try await workspace.head(of: directory)
                    try await write(node.id, by: author, [
                        .runFinished(run: run, outcome: "already satisfied; submitted the branch unchanged"),
                        .changeSubmitted(run: run, commit: head), .phaseChanged(to: .checking)])
                    return "\(node.ticket) already satisfied (\(run)) → Checking"
                }
                guard node.landingReworkPending else { throw AgentFailure("submitted no changes") }
                try await write(node.id, by: author, [
                    .runFinished(run: run, outcome: "submitted no changes; rerunning landing check"),
                    .landingRerunRequested(run: run),
                    .phaseChanged(to: .landing),
                ])
                return "\(node.displayName) submitted no changes after landing rework → Landing queue"
            }
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "submitted"),
                .assumptionsReported(role: .implementer, assumptions: assumptions),
                .changeSubmitted(run: run, commit: commit),
                .phaseChanged(to: .checking),
            ])
            return "\(node.displayName) implemented by \(run) → Checking"
        } catch let error as UserGitStateChanged {
            // Not something another attempt fixes: a human checks what happened to their repo first.
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"), .attemptFailed(summary: "\(error)"), .phaseChanged(to: .ready),
                .flagSet(.escalated, reason: "\(error)")])
            await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(error)\nWhen checked, add label harness:retry.")
            return "\(node.displayName) escalated: \(error)"
        } catch {
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"), .attemptFailed(summary: "\(error)"), .phaseChanged(to: .ready)])
            return try await escalateIfNeeded(node.id) ?? "\(node.displayName) implementer failed (\(error)); will retry"
        }
    }

    /// The implementer changed nothing for the change review's findings. Submitting the same branch again would only
    /// repeat that review, so a person decides: the findings may be about the tests, or simply wrong.
    private func disputeReviewFindings(
        _ findings: String, on node: NodeState, run: RunID, author: Participant
    ) async throws -> String {
        let reason = """
            The implementer made no changes for the change review's findings:
            \(findings)
            Next: if they are about this ticket's acceptance tests, comment how to change them, then add \
            harness:retest. If the code should change, comment how, then add harness:retry. If the findings are \
            wrong, say so in a comment, then add harness:retry.
            """
        try await write(node.id, by: author, [
            .runFinished(run: run, outcome: Self.unaddressedFindingsOutcome),
            .phaseChanged(to: .ready),
            .flagSet(.needsInput, reason: reason),
        ])
        await tracker.comment(on: node.ticket, "\(Self.needsInputMarker): \(reason)")
        return "\(node.displayName) made no changes for the review findings → waiting for a person"
    }

    private func routeBrokenTest(
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

    /// Fast feedback on the leaf's own branch: only its own acceptance tests (doc 08 §4, layer 2).
    private func preCheck(_ node: NodeState) async throws -> String {
        guard let submission = node.lastSubmission else { return "\(node.displayName): nothing submitted" }
        let run = Self.newRunID()
        let directory = workspace.worktree(for: node.id)
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .verifier)], expecting: node.version)

        var output: CheckOutput
        if let tampered = try await protectedTestsViolation(node, in: directory) {
            output = CheckOutput(passed: false, summary: tampered, log: tampered)
        } else {
            try await workspace.prepareBuild(in: directory)
            output = await checks.runChecks(in: directory, only: node.spec.testTarget)
            if case .runnerCrash = output.failureKind {
                output = await checks.runChecks(in: directory, only: node.spec.testTarget)
            }
        }
        if case .runnerCrash = output.failureKind {
            return try await recordRepeatedRunnerCrash(
                node,
                output: output,
                check: "own acceptance tests on branch",
                builtBy: submission.run,
                checkedBy: run,
                commit: submission.commit
            )
        }
        try Task.checkCancellation()
        let evidence = try makeEvidence(node, check: "own acceptance tests on branch", output: output,
                                        builtBy: submission.run, checkedBy: run, commit: submission.commit,
                                        failureClassification: output.passed ? nil : .ownMistake)
        try await write(node.id, by: .agent(run: run, role: .verifier), [
            .evidenceRecorded(evidence), .runFinished(run: run, outcome: output.passed ? "passed" : "failed"),
            .phaseChanged(to: output.passed ? .landing : .ready)])
        if output.passed { return "\(node.displayName) pre-checked by \(run) → Landing queue" }
        await tracker.comment(on: node.ticket, "🔁 Pre-check failed; this is the agent's own mistake: \(output.summary)")
        return try await escalateIfNeeded(node.id) ?? "\(node.displayName) failed pre-check; will retry"
    }

    /// The landing queue (doc 08 §4, layer 3): rebase onto the latest main, run ALL tests (own + every proven
    /// node's), and only then merge. A leaf is proven only once it has landed.
    private func land(_ node: NodeState) async throws -> String {
        guard let submission = node.lastSubmission else { return "\(node.displayName): nothing to land" }
        let run = Self.newRunID()
        let checker = Participant.agent(run: run, role: .verifier)
        let directory = workspace.worktree(for: node.id)
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .verifier)], expecting: node.version)

        // 1. Textual conflict → rework from the latest main. Not the agent's fault, so not a failed attempt.
        if case .conflict(let files) = try await workspace.rebaseOntoMain(directory) {
            try await workspace.resetForRework(directory)
            let reason = "merge conflict in \(files.isEmpty ? "some files" : files.joined(separator: ", ")) with newer work on main"
            try await write(node.id, by: checker, [
                .runFinished(run: run, outcome: "conflict"), .reworkNeeded(reason: reason), .phaseChanged(to: .ready)])
            await tracker.comment(on: node.ticket, "♻️ Rework: \(reason). The implementation is redone on the latest code; the tests are kept.")
            return try await escalateIfNeeded(node.id) ?? "\(node.displayName) conflicted at landing → rework"
        }

        // 2. Re-check everything on top of the latest main.
        var output: CheckOutput
        if let tampered = try await protectedTestsViolation(node, in: directory) {
            output = CheckOutput(passed: false, summary: tampered, log: tampered)
        } else {
            try await workspace.prepareBuild(in: directory)
            output = await checks.runChecks(in: directory, only: nil)
            if case .runnerCrash = output.failureKind {
                output = await checks.runChecks(in: directory, only: nil)
            }
        }
        let candidate = try await workspace.head(of: directory)
        if case .runnerCrash = output.failureKind {
            return try await recordRepeatedRunnerCrash(
                node,
                output: output,
                check: "all tests on latest main (landing)",
                builtBy: submission.run,
                checkedBy: run,
                commit: candidate
            )
        }
        let state = await ledger.workingState()
        let provenTargets = Set(state.nodes.values.filter { $0.phase == .proven }.map(\.spec.testTarget))
        var diagnosis: String?
        if !output.passed && !output.failingTargets.isEmpty
            && !output.failingTargets.contains(node.spec.testTarget)
            && output.failingTargets.isSubset(of: provenTargets) {
            let initial = output
            let baseline = await checkLatestMain()
            var repeated = await checks.runChecks(in: directory, only: nil)
            if case .runnerCrash = repeated.failureKind {
                repeated = await checks.runChecks(in: directory, only: nil)
            }
            let failures = initial.log.split(separator: "\n").filter { line in
                initial.failingTargets.contains { line.contains($0) }
                    || line.localizedCaseInsensitiveContains("fail")
                    || line.contains("recorded an issue") || line.contains("error:")
            }.joined(separator: "\n")
            let report = """
                Initial landing failure: \(initial.summary)
                Failing tests:
                \(failures.isEmpty ? initial.log : failures)
                Without the change on latest agentos/main: \(baseline.summary)
                With the change again: \(repeated.summary)
                """
            diagnosis = report
            output = CheckOutput(
                passed: repeated.passed,
                summary: report,
                log: """
                    Initial landing check:
                    \(initial.log)
                    Without the change on latest agentos/main:
                    \(baseline.log)
                    With the change again:
                    \(repeated.log)
                    """,
                failingTargets: repeated.failingTargets,
                failureKind: repeated.failureKind
            )
            if !baseline.passed || repeated.failureKind != .reportedFailure {
                let reason = """
                    Landing infrastructure problem on agentos/main; no failed attempt counted.
                    \(report)
                    Fix the baseline or test runner, then add harness:retry.
                    """
                let diagnosticEvidence = try makeEvidence(
                    node, check: "landing failure diagnosis", output: CheckOutput(
                        passed: false, summary: reason, log: output.log
                    ),
                    builtBy: submission.run, checkedBy: run, commit: candidate,
                    failureClassification: .landingInfrastructure
                )
                try await write(node.id, by: checker, [
                    .evidenceRecorded(diagnosticEvidence),
                    .runFinished(run: run, outcome: "landing infrastructure problem"),
                    .flagSet(.escalated, reason: reason),
                ])
                await tracker.comment(on: node.ticket, reason)
                return "\(node.displayName) landing infrastructure problem → needs human"
            }
        }
        var evidence = try makeEvidence(node, check: "all tests on latest main (landing)", output: output,
                                        builtBy: submission.run, checkedBy: run, commit: candidate)

        // 3. Merge.
        if output.passed {
            if team.reviewer != nil, policy.review.requiresReview {
                let context = try await workspace.reviewContext(in: directory, against: policy.review.baseBranch)
                let level = policy.review.level(for: node.spec.touches + context.changedFiles)
                if level != .none {
                    let current = await ledger.workingState().nodes[node.id] ?? node
                    let prior = current.reviews.last { $0.stage == .change }
                    let result: ReviewResult
                    if let prior, prior.commit == context.commit, prior.result.passed {
                        result = prior.result
                    } else {
                        result = try await review(node, stage: .change, context: context, in: directory, run: run)
                    }
                    if !result.passed {
                        try await write(node.id, by: checker, [.evidenceRecorded(evidence)])
                        return try await returnReviewFindings(result, stage: .change, node: node, run: run, directory: directory)
                    }
                    if level == .agentAndHuman, current.approvedReviewCommit != context.commit {
                        try await write(node.id, by: checker, [
                            .evidenceRecorded(evidence), .runFinished(run: run, outcome: "waiting for human review"),
                            .humanReviewRequested(commit: context.commit),
                        ])
                        let screenshots = context.uiEvidence.map {
                            "\nBefore screenshot: \($0.beforeScreenshot ?? "missing")\nAfter screenshot: \($0.afterScreenshot ?? "missing")"
                        } ?? ""
                        await tracker.comment(on: node.ticket, """
                            Agent review passed for \(context.commit).
                            \(result.findings.joined(separator: "\n"))\(screenshots)
                            Review the change, then add harness:build to approve this candidate.
                            """)
                        return "\(node.displayName) → In review"
                    }
                }
            }
            try Task.checkCancellation()
            let main = try await workspace.landOnMain(node.id)
            try await write(node.id, by: checker, [
                .evidenceRecorded(evidence), .landed(commit: main), .runFinished(run: run, outcome: "landed"),
                .phaseChanged(to: .proven)])
            try? await workspace.removeWorktree(for: node.id)
            if let diagnosis {
                await tracker.comment(on: node.ticket, "Unreliable test in the initial landing check; both reruns passed.\n\(diagnosis)")
            }
            await tracker.comment(on: node.ticket, "🛬 Landed on main at \(main.prefix(8)) with all tests passing.")
            return "\(node.displayName) landed by \(run) → Proven"
        }

        // Which node's behaviour broke? Someone else's → two requirements may contradict (doc 08 §5).
        let broken = output.failingTargets.subtracting([node.spec.testTarget])
            .compactMap { target in state.nodes.values.first { $0.spec.testTarget == target && $0.phase == .proven } }
        var kinds: [EventKind] = [.evidenceRecorded(evidence), .runFinished(run: run, outcome: "failed"), .phaseChanged(to: .ready)]
        if let diagnosis, !broken.isEmpty && !output.failingTargets.contains(node.spec.testTarget)
            && output.failingTargets.isSubset(of: provenTargets) {
            let names = broken.map { "\($0.displayName) (\($0.spec.title))" }.joined(separator: ", ")
            let reason = """
                Requirements conflict: this change breaks proven behaviour of \(names). A human must decide which requirement wins.
                \(diagnosis)
                Next: comment with guidance, then add harness:retry.
                """
            kinds.append(.flagSet(.escalated, reason: reason))
            try await write(node.id, by: checker, kinds)
            await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(reason)")
            for other in broken {
                await tracker.comment(on: other.ticket, "ℹ️ \(node.displayName) (\(node.spec.title)) contradicts this ticket's acceptance criteria. Escalated there.")
            }
            return "\(node.displayName) breaks \(broken.map(\.displayName).joined(separator: ", ")) → requirements conflict, escalated"
        }
        evidence.failureClassification = .ownMistake
        let reranSameCandidate = node.evidence.last?.commit == candidate
        if node.landingRerunPending && reranSameCandidate {
            let reason = "Landing rerun failed; this is the agent's own mistake: \(output.summary)"
            kinds[0] = .landingReworkNeeded(evidence)
            kinds.append(.attemptFailed(summary: reason))
            try await write(node.id, by: checker, kinds)
            await tracker.comment(on: node.ticket, "🔁 \(reason)")
            return try await escalateIfNeeded(node.id) ?? "\(node.displayName) failed landing rerun; will retry"
        }
        let alreadyPassedOwnCheck = node.evidence.contains {
            $0.passed && $0.check == "own acceptance tests on branch" && $0.commit == submission.commit
        }
        if !alreadyPassedOwnCheck {
            let reason = "Landing check failed; this is the agent's own mistake: \(output.summary)"
            try await write(node.id, by: checker, [
                .evidenceRecorded(evidence), .runFinished(run: run, outcome: "failed"), .phaseChanged(to: .ready),
            ])
            await tracker.comment(on: node.ticket, "🔁 \(reason)")
            return try await escalateIfNeeded(node.id) ?? "\(node.displayName) failed at landing; will retry"
        }
        kinds[0] = .landingReworkNeeded(evidence)
        try await write(node.id, by: checker, kinds)
        let cause = node.landingRerunPending ? " after main moved" : ""
        await tracker.comment(
            on: node.ticket,
            "♻️ Landing check failed\(cause); this is the agent's own mistake: \(output.summary). "
                + "The implementer will rework the candidate."
        )
        return try await escalateIfNeeded(node.id) ?? "\(node.displayName) failed at landing; will retry"
    }

    // MARK: Helpers

    private func checkLatestMain() async -> CheckOutput {
        do {
            guard let snapshot = try await workspace.createSnapshot() else {
                throw AgentFailure("Workspace cannot create a latest agentos/main snapshot")
            }
            do {
                try await workspace.prepareBuild(in: snapshot)
            } catch {
                await workspace.removeSnapshot(snapshot)
                throw error
            }
            var output = await checks.runChecks(in: snapshot, only: nil)
            if case .runnerCrash = output.failureKind {
                output = await checks.runChecks(in: snapshot, only: nil)
            }
            await workspace.removeSnapshot(snapshot)
            return output
        } catch {
            return CheckOutput(
                passed: false, summary: "Could not check latest agentos/main: \(error)", log: "\(error)"
            )
        }
    }

    private func recordRepeatedRunnerCrash(
        _ node: NodeState,
        output: CheckOutput,
        check: String,
        builtBy: RunID,
        checkedBy: RunID,
        commit: String
    ) async throws -> String {
        let evidence = try makeEvidence(
            node,
            check: check,
            output: output,
            builtBy: builtBy,
            checkedBy: checkedBy,
            commit: commit,
            failureClassification: .runnerCrash
        )
        let reason = "Runner crash repeated after one retry: \(output.summary)"
        try await write(node.id, by: .agent(run: checkedBy, role: .verifier), [
            .evidenceRecorded(evidence),
            .runFinished(run: checkedBy, outcome: "runner crash"),
            .flagSet(.escalated, reason: reason),
        ])
        let tail = output.log.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(60)
            .joined(separator: "\n")
        await tracker.comment(on: node.ticket, """
            ⚠️ Needs a human: \(reason)
            Full stored log: \(evidence.artifactPath)

            <details>
            <summary>Last 60 runner log lines</summary>

            \(tail)
            </details>

            When the runner is available, add harness:retry.
            """)
        return "\(node.displayName) runner crash repeated → needs human"
    }

    private func escalateIfNeeded(_ id: NodeID) async throws -> String? {
        guard let node = await ledger.workingState().nodes[id], let reason = policy.escalationReason(for: node) else { return nil }
        try await write(id, by: .reconciler, [.flagSet(.escalated, reason: reason)])
        await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(reason)\nWhen fixed, add label harness:retry.")
        return "\(node.displayName) escalated: \(reason)"
    }

    /// What the node still waits for: its own links and specs, plus a parent's "Blocked by" that its breakdown didn't
    /// give to particular children (then it applies to all of them, e.g. a forgotten dependency added by replan).
    /// A dependency is met when the other system delivered it, or when it's another ticket (or node) here and that
    /// is proven.
    private func unresolvedDependencies(of node: NodeState, in state: WorkingState) -> [String] {
        let ancestors = state.lineage(of: node.id).dropFirst()
        let inherited = ancestors.flatMap { ancestor in
            ancestor.spec.dependsOn.filter { ref in
                !state.subtree(of: ancestor.id).dropFirst().contains { $0.spec.dependsOn.contains(ref) }
            }
        }
        let wanted = node.links.filter { $0.type == .dependsOn }.map(\.to) + node.spec.dependsOn + inherited
        let siblings = (node.spec.after ?? []).compactMap { hash -> String? in
            let parent = node.spec.parent.flatMap { state.nodes[$0] }
            // A sibling the latest breakdown no longer has can't be waited for.
            guard let sibling = parent?.children.lazy.compactMap({ state.nodes[$0] })
                .first(where: { $0.spec.specHash == hash }) else { return nil }
            return sibling.phase == .proven ? nil : sibling.displayName
        }
        var seen = Set<String>()
        return siblings + wanted.filter { seen.insert($0).inserted }.filter { ref in
            if state.resolvedExternal.contains(ref) { return false }
            let here = state.nodes[ref] ?? state.node(forTicket: ref)
            return here?.phase != .proven
        }
    }

    /// The decomposer looks at a snapshot of the latest code when the workspace can make one. Without it the
    /// breakdown still runs, from the ticket alone.
    private func propose(
        _ spec: NodeSpec, ticketKey: String, clarifications: [Clarification], log: URL?
    ) async throws -> Breakdown {
        let codebase = try? await workspace.createSnapshot()
        let request = BreakdownRequest(
            spec: spec, existingComponents: workspace.existingComponents(), clarifications: clarifications,
            guesswork: policy.guesswork, log: log, codebase: codebase, ticketKey: ticketKey,
            agentContext: await makeAgentContext(ticketKey))
        do {
            let breakdown = try await team.decomposer.proposeChildren(request)
            if let codebase { await workspace.removeSnapshot(codebase) }
            return breakdown
        } catch {
            if let codebase { await workspace.removeSnapshot(codebase) }
            throw error
        }
    }

    /// A fresh file for the run's own output (see `AgentLog`). Not having one never stops the work.
    private func agentLog(_ node: NodeState, _ run: RunID) -> URL? {
        try? artifacts.liveFile(named: AgentLog.fileName(node: node.id, run: run))
    }

    /// Agents may only change their own worktree and branch. Anything else in your repo (fetched or new refs,
    /// stashes, config, hooks) means an agent got around its denied tools. With agents running side by side,
    /// the change can't be pinned on one: every agent that ran at the same time is named, and each of them
    /// notices the change itself too.
    private func watchingUserGitState<T>(_ node: NodeState, run: RunID, _ agent: () async throws -> T) async throws -> T {
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

    private struct AgentRunSpan {
        let ticket: String
        let start: Int
        var end: Int?
    }

    private func withScratchDirectory<T>(_ directory: URL, operation: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation()
    }

    private func makeAgentContext(_ key: String) async -> AgentContext {
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

    private func review(_ node: NodeState, stage: ReviewStage, context: ReviewContext,
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

    private func returnReviewFindings(_ result: ReviewResult, stage: ReviewStage,
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

    private func makeTask(_ node: NodeState, run: RunID, in directory: URL, log: URL?,
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

    private static func uniqueLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }

    private func testsDigest(_ node: NodeState, in directory: URL) -> String {
        Hashing.digest(of: directory.appending(path: workspace.testFolder(for: node.spec)))
    }

    /// Acceptance tests are locked: the node's own must match their fingerprint, and the branch may not touch
    /// any other node's tests (the implementer must never "fix" a conflict by editing someone else's tests),
    /// nor any protected path (e.g. the agents' own instructions).
    private func protectedTestsViolation(_ node: NodeState, in directory: URL) async throws -> String? {
        if testsDigest(node, in: directory) != node.testsDigest {
            return "Acceptance tests were changed after they were fixed (not allowed)"
        }
        let changed = try await workspace.changedFiles(in: directory)
        let own = workspace.testFolder(for: node.spec) + "/"
        let others = changed.filter { $0.hasPrefix(workspace.testArea) && !$0.hasPrefix(own) }
        if !others.isEmpty { return "Changed other nodes' tests (not allowed): \(others.joined(separator: ", "))" }
        let protected = policy.protectedPathViolations(changed)
        return protected.isEmpty ? nil : "Changed protected files (not allowed): \(protected.joined(separator: ", "))"
    }

    private func makeEvidence(_ node: NodeState, check: String, output: CheckOutput, builtBy: RunID, checkedBy: RunID,
                              commit: String, failureClassification: FailureClassification? = nil) throws -> Evidence {
        let artifact = try artifacts.put(named: "\(node.id)-\(checkedBy).log", contents: Data(output.log.utf8))
        return Evidence(check: check, passed: output.passed, summary: output.summary, specHash: node.spec.specHash,
                        builtBy: builtBy, checkedBy: checkedBy, artifactPath: artifact.path, artifactSHA256: artifact.sha256,
                        commit: commit, failureClassification: failureClassification)
    }

    private func projectStatuses() async {
        let state = await ledger.workingState()
        for node in state.nodes.values where !node.ticketClosed {
            await tracker.setStatus(of: node.ticket, to: state.status(of: node))
        }
    }

    /// One node's status and its children's (theirs depends on the parent's phase), as soon as it changes:
    /// a round can take as long as its slowest agent or landing check, so waiting for its end left tickets
    /// showing a status from half an hour ago.
    private func projectStatus(of id: NodeID) async {
        let state = await ledger.workingState()
        guard let node = state.nodes[id] else { return }
        for affected in [node] + node.children.compactMap({ state.nodes[$0] }) where !affected.ticketClosed {
            await tracker.setStatus(of: affected.ticket, to: state.status(of: affected))
        }
    }

    private func write(_ node: NodeID?, by who: Participant, _ kinds: [EventKind], expecting version: Int? = nil) async throws {
        try Task.checkCancellation()
        let events = kinds.map { LedgerEvent(node: node, by: who, kind: $0) }
        let expecting = node.flatMap { id in version.map { [id: $0] } } ?? [:]
        let starting = kinds.compactMap { kind -> RunID? in
            if case .runStarted(let run, _) = kind { return run }
            return nil
        }.first
        if let node, let starting { ownedRuns[node] = starting }
        do {
            try await ledger.append(events, expecting: expecting)
        } catch {
            if let node, starting != nil { ownedRuns[node] = nil }
            throw error
        }
        if let node { await projectStatus(of: node) }
    }

    static func newRunID() -> RunID { "run-" + UUID().uuidString.prefix(6).lowercased() }
}
