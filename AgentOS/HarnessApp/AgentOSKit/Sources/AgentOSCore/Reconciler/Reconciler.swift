import Foundation

public struct RoundReport: Sendable {
    public var actions: [String] = []
    /// Set when the reconciler refused to act (e.g. the ledger failed its integrity check).
    public var safeStop: String?
    public var isIdle: Bool { actions.isEmpty }
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
    public nonisolated let policy: Policy
    public private(set) var team: AgentTeam
    /// When each agent of the current round started and finished, in steps of `clock`.
    private var agentRuns: [RunID: AgentRunSpan] = [:]
    private var clock = 0

    public init(ledger: Ledger, tracker: any TrackerAdapter, external: any ExternalDependencySource,
                workspace: any Workspace, artifacts: any ArtifactStore, checks: any CheckRunner, team: AgentTeam,
                policy: Policy = Policy()) {
        self.ledger = ledger
        self.artifacts = artifacts
        self.tracker = tracker
        self.external = external
        self.workspace = workspace
        self.checks = checks
        self.team = team
        self.policy = policy
    }

    public func setTeam(_ team: AgentTeam) { self.team = team }

    // MARK: The loop

    public func runRound() async -> RoundReport {
        var report = RoundReport()
        let chain = await ledger.verifyChain()
        if let problem = chain.problem {
            report.safeStop = "Ledger integrity check failed at #\(problem.position): \(problem.reason). " +
                "Safe stop: nothing will happen until a human investigates."
            return report
        }
        do { try await workspace.prepare() } catch {
            report.safeStop = "Workspace repository unavailable: \(error)"
            return report
        }

        await intakeSignals(&report)
        await intakeExternal(&report)

        await advanceAll(&report)

        // The landing queue: the only place where work happens strictly one at a time (doc 08 §4).
        for node in await ledger.workingState().landingQueue {
            do {
                report.actions.append(try await land(node))
            } catch LedgerError.conflict {
                continue
            } catch {
                report.actions.append("⚠️ \(node.ticket): \(error)")
            }
        }

        await projectStatuses()
        return report
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
            notes.append("Reclaimed \(node.ticket) from \(active.run)")
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

        switch signal.command {
        case .preview:
            // A preview does NOT adopt the ticket and creates nothing (doc 05 §3).
            let problems = policy.readinessProblems(ticket)
            guard problems.isEmpty else { throw Rejection(reason: "Not ready yet. Missing: \(problems.joined(separator: ", ")).") }
            let spec = Planner.rootSpec(for: ticket)
            let breakdown = try await propose(spec, clarifications: [], log: nil)
            let questions = policy.questions(in: breakdown.report)
            guard questions.isEmpty else {
                // Nothing is recorded: the ticket isn't adopted, so its description is where the answers go.
                await tracker.comment(on: ticket.key, """
                    ❓ The decomposer has questions before it can propose a breakdown:
                    \(Self.numbered(questions))
                    Edit the ticket to answer them, then preview again.
                    """)
                return "questions posted above; no preview recorded"
            }
            let children = Planner.childSpecs(parent: spec, proposals: breakdown.children)
            let number = (state.previews[ticket.key]?.number ?? 0) + 1
            try await write(nil, by: .reconciler, [
                .previewRecorded(ticket: ticket.key, number: number, specHash: spec.specHash, proposal: children)])
            // Accepting the preview accepts its assumptions too: they aren't asked about again.
            await tracker.comment(on: ticket.key, """
                🔍 Preview #\(number). Nothing has been created.
                \(Planner.describe(children, under: ticket.title))\(Self.assumptionsNote("Assumptions the decomposer made", breakdown.report.assumptions))
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
                try await write(node.id, by: .human(person), [.gateOpened(.breakdown)])
                return "breakdown approved"
            }
            let problems = policy.readinessProblems(ticket)
            guard problems.isEmpty else { throw Rejection(reason: "Not ready yet. Missing: \(problems.joined(separator: ", ")).") }
            let spec = Planner.rootSpec(for: ticket)
            // Adoption: from now on the harness owns the node; the ticket shows a projection of it.
            try await write(spec.id, by: .human(person), [.nodeCreated(spec: spec, ticket: ticket.key), .gateOpened(.breakdown)])
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
            guard let node, node.flags[.escalated] != nil else {
                throw Rejection(reason: "Nothing to retry. \(HarnessCommand.retry.label) only continues work that stopped: " +
                    "an escalation, or questions or a review waiting for you.")
            }
            try await write(node.id, by: .human(person), [.flagCleared(.escalated), .attemptsReset])
            return "escalation cleared; attempts reset"

        case .replan:
            return try await replan(node, ticket: ticket, by: person)

        case .go:
            // Both gates at once: the readiness checks for both run now, so nothing stops halfway for lack
            // of permission. Production: also checks the build budget is set (doc 05 §5).
            if let node {
                let missing = [Gate.breakdown, .build].filter { !node.gates.contains($0) }
                let reviews = waitingForReview(under: node.id, in: state)
                guard !missing.isEmpty || !reviews.isEmpty else { throw Rejection(reason: "Breakdown and build are already approved.") }
                if !missing.isEmpty { try await write(node.id, by: .human(person), missing.map { .gateOpened($0) }) }
                let approved = missing.isEmpty ? "build" : missing.map(\.rawValue).joined(separator: " and ")
                return "\(approved) approved for \(node.spec.id) and everything below it" + (try await approve(reviews, by: person))
            }
            let problems = policy.readinessProblems(ticket)
            guard problems.isEmpty else { throw Rejection(reason: "Not ready yet. Missing: \(problems.joined(separator: ", ")).") }
            let spec = Planner.rootSpec(for: ticket)
            try await write(spec.id, by: .human(person), [
                .nodeCreated(spec: spec, ticket: ticket.key), .gateOpened(.breakdown), .gateOpened(.build)])
            return "adopted; breakdown and build approved: it will be broken down, built and checked without stopping\n"
                + spec.trackerSummary
        }
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
            throw Rejection(reason: "\(ticket.key) is part of \(parent.ticket)'s breakdown. Replan \(parent.ticket) instead, " +
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
        let waits = spec.dependsOn.isEmpty ? "" : "\nWaits for: \(spec.dependsOn.joined(separator: ", "))."
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
        guard let answer = Self.answer(on: ticket) else {
            throw Rejection(reason: "Answer \(node.openQuestions.isEmpty ? "the review request" : "the questions") above in a comment " +
                "first, then add harness:retry again. To build the tests as they are, add harness:build instead.")
        }
        let isReview = node.openQuestions.isEmpty
        var kinds: [EventKind] = [
            .questionsAnswered(Clarification(questions: isReview ? ["Feedback on the acceptance tests"] : node.openQuestions, answer: answer)),
            .flagCleared(.needsInput)]
        if isReview && node.spec.kind == .leaf && node.phase == .ready {
            try? await workspace.removeWorktree(for: node.id)
            kinds.append(.phaseChanged(to: .specified))
        }
        if node.flags[.escalated] != nil { kinds += [.flagCleared(.escalated), .attemptsReset] }
        try await write(node.id, by: .human(person), kinds)
        return isReview ? "feedback recorded; the acceptance tests will be written again with it" : "answer recorded; work continues with it"
    }

    /// Human comments after the harness's latest "Needs input" comment, or nil when nobody answered yet.
    static func answer(on ticket: Ticket) -> String? {
        guard let asked = ticket.comments.lastIndex(where: { !$0.author.isHuman && $0.text.contains(needsInputMarker) }) else { return nil }
        let replies = ticket.comments[(asked + 1)...].filter(\.author.isHuman).map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return replies.isEmpty ? nil : replies.joined(separator: "\n\n")
    }

    static let needsInputMarker = "❓ Needs input"

    /// Leaves below `id` (or `id` itself) whose acceptance tests wait for a person's review before build.
    private func waitingForReview(under id: NodeID, in state: WorkingState) -> [NodeState] {
        state.subtree(of: id).filter { $0.flags[.needsInput] != nil && $0.openQuestions.isEmpty && $0.phase == .ready }
    }

    /// `harness:build` or `harness:go` approves the tests of the leaves waiting for review.
    private func approve(_ reviews: [NodeState], by person: String) async throws -> String {
        for node in reviews { try await write(node.id, by: .human(person), [.flagCleared(.needsInput)]) }
        return reviews.isEmpty ? "" : "; acceptance tests approved for \(reviews.map(\.ticket).joined(separator: ", "))"
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
                report.actions.append("\(node.ticket) unblocked")
            }
        }
    }

    // MARK: Controllers: one step per node per round

    /// One step per node, up to `maxParallelAgents` nodes at a time. The steps interleave only while they wait
    /// (for an agent, a check, git): each node has its own branch and working copy, and every claim is a
    /// compare-and-swap on the node's version. Actions are reported in node order, whatever finished first.
    private func advanceAll(_ report: inout RoundReport) async {
        agentRuns.removeAll()
        let order = await ledger.workingState().creationOrder
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

    private func step(_ id: NodeID) async -> String? {
        let state = await ledger.workingState()
        guard let node = state.nodes[id] else { return nil }
        do {
            return try await advance(node, in: state)
        } catch LedgerError.conflict {
            return nil // The node changed meanwhile; the next round sees the new state.
        } catch {
            return "⚠️ \(node.ticket): \(error)"
        }
    }

    private func advance(_ node: NodeState, in state: WorkingState) async throws -> String? {
        guard node.flags[.escalated] == nil, node.flags[.needsInput] == nil, node.activeRun == nil else { return nil }
        // The parent was replanned: its children wait for its new breakdown.
        if let parent = node.spec.parent.flatMap({ state.nodes[$0] }), parent.phase != .split { return nil }

        switch (node.spec.kind, node.phase) {
        case (.composite, .specified):
            guard state.hasGate(.breakdown, at: node.id) else { return nil }
            return try await breakDown(node, in: state)

        case (.composite, .split):
            let children = node.children.compactMap { state.nodes[$0] }
            guard !children.isEmpty, children.allSatisfy({ $0.phase == .proven }) else { return nil }
            // Up the V: every child has landed with all tests passing on main, so the whole is proven.
            try await write(node.id, by: .reconciler, [.phaseChanged(to: .proven)], expecting: node.version)
            await tracker.comment(on: node.ticket, "✅ Proven: every child has landed with all tests passing on main.")
            return "\(node.ticket) proven (all children proven)"

        case (.leaf, .specified):
            guard state.hasGate(.breakdown, at: node.id) else { return nil }
            return try await authorTests(node)

        case (.leaf, .ready):
            guard state.hasGate(.build, at: node.id) else { return nil }
            let missing = unresolvedDependencies(of: node, in: state)
            guard missing.isEmpty else {
                guard node.flags[.blocked] == nil else { return nil }
                let reason = "Waiting for \(missing.joined(separator: ", "))"
                try await write(node.id, by: .reconciler, [.flagSet(.blocked, reason: reason)], expecting: node.version)
                await tracker.comment(on: node.ticket, "⏸ Blocked: \(reason).")
                return "\(node.ticket) blocked"
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
            proposed = preview.proposal
            author = .reconciler
        } else {
            let run = Self.newRunID()
            author = .agent(run: run, role: .decomposer)
            try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .decomposer)], expecting: node.version)
            let breakdown: Breakdown
            do {
                breakdown = try await propose(node.spec, clarifications: state.clarifications(for: node.id), log: agentLog(node, run))
            } catch {
                try await write(node.id, by: author, [
                    .runFinished(run: run, outcome: "failed: \(error)"),
                    .flagSet(.escalated, reason: "Breakdown failed: \(error)")])
                await tracker.comment(on: node.ticket, "⚠️ Needs a human: breakdown failed (\(error)). Fix the ticket, then add harness:retry.")
                return "\(node.ticket) breakdown failed → escalated"
            }
            let questions = policy.questions(in: breakdown.report)
            guard questions.isEmpty else {
                return try await raise(questions, on: node, by: author, run: run, role: .decomposer)
            }
            proposed = Planner.childSpecs(parent: node.spec, proposals: breakdown.children)
            assumptions = breakdown.report.assumptions
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
            return "\(node.ticket) passed the leaf check: built as one leaf"
        }

        for spec in children {
            // Child ids are deterministic: after a failed attempt, the ones already created are kept.
            if await ledger.workingState().nodes[spec.id] != nil { continue }
            let key: String
            do {
                key = try await tracker.createChildTicket(parent: node.ticket, spec: spec, by: author)
            } catch {
                try await write(node.id, by: .reconciler, [.flagSet(.escalated, reason: "Couldn't create a child ticket: \(error)")])
                return "\(node.ticket) breakdown stopped: couldn't create \"\(spec.title)\" → escalated"
            }
            let links = spec.dependsOn.map { TypedLink(from: spec.id, type: .dependsOn, to: $0) }
            try await write(spec.id, by: author, [.nodeCreated(spec: spec, ticket: key)] + links.map { .linkAdded($0) })
        }
        try await write(node.id, by: .reconciler, [.phaseChanged(to: .split)])
        await tracker.comment(on: node.ticket, """
            🌳 Broken down. Each leaf gets its own branch and acceptance tests next; then add harness:build.
            \(Planner.describe(children, under: node.spec.title))\(note)\(revision)
            """)
        return "\(node.ticket) broken down into \(children.count) leaves"
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
            await tracker.close(gone.ticket, saying: "🗑 Superseded: \(node.ticket) was replanned and its new breakdown doesn't contain this.")
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
        let task = await makeTask(node, run: run, in: directory, log: agentLog(node, run))
        let own = workspace.testFolder(for: node.spec) + "/"
        let report: AgentReport
        do {
            report = try await watchingUserGitState(node, run: run) { try await team.testAuthor.writeAcceptanceTests(task) }
        } catch {
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"),
                .flagSet(.escalated, reason: "Couldn't write acceptance tests: \(error)")])
            return "\(node.ticket) test authoring failed → escalated"
        }
        let questions = policy.questions(in: report)
        guard questions.isEmpty else {
            // Tests written on a guess aren't kept: the branch starts over once the questions are answered.
            try? await workspace.removeWorktree(for: node.id)
            return try await raise(questions, on: node, by: author, run: run, role: .testAuthor)
        }
        let testFiles: [String]
        do {
            let changed = try await workspace.commitAll(in: directory, message: "\(node.spec.id): acceptance tests", author: run)
            // After the commit, so the check sees everything the author wrote (changes are compared commit to commit).
            let outside = try await workspace.changedFiles(in: directory).filter { !$0.hasPrefix(own) }
            guard outside.isEmpty, changed != nil else {
                throw AgentFailure(changed == nil ? "no tests written" : "wrote outside its own test folder \(own): \(outside.joined(separator: ", "))")
            }
            testFiles = try await workspace.changedFiles(in: directory).filter { $0.hasPrefix(own) }
        } catch {
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"),
                .flagSet(.escalated, reason: "Couldn't write acceptance tests: \(error)")])
            return "\(node.ticket) test authoring failed → escalated"
        }

        // Under "assume and report", a leaf whose work rests on assumptions waits for a person to see its tests,
        // unless they already answered something on it. Questions about what users observe stopped it above.
        let state = await ledger.workingState()
        let review = policy.guesswork == .assumeAndReport && (!report.assumptions.isEmpty
            || (!state.assumptions(for: node.id).isEmpty && state.clarifications(for: node.id).isEmpty))
        let reviewReason = "Review the acceptance tests and assumptions, then add harness:build"
        try await write(node.id, by: author, [
            .runFinished(run: run, outcome: "acceptance tests committed"), .testsFixed(digest: testsDigest(node, in: directory)),
            .assumptionsReported(role: .testAuthor, assumptions: report.assumptions), .phaseChanged(to: .ready)]
            + (review ? [.flagSet(.needsInput, reason: reviewReason)] : []))
        let reviewNote = review ? """

            \(Self.needsInputMarker): \(reviewReason.prefix(1).lowercased() + reviewReason.dropFirst()) to approve them as they are, \
            or comment what to change and add harness:retry.
            """ : ""
        await tracker.comment(on: node.ticket, """
            🧪 Acceptance tests written on branch \(workspace.branch(for: node.id)):
            \(Self.testListing(testFiles, in: directory))\(Self.assumptionsNote("Assumptions this work rests on", await ledger.workingState().assumptions(for: node.id)))\(reviewNote)
            """)
        return "\(node.ticket) acceptance tests written on branch \(workspace.branch(for: node.id)) → " + (review ? "waiting for review" : "Ready")
    }

    /// The agent can't go on without a person: record its questions and ask on the ticket.
    private func raise(_ questions: [String], on node: NodeState, by author: Participant, run: RunID, role: AgentRole) async throws -> String {
        let plural = questions.count == 1 ? "question" : "questions"
        try await write(node.id, by: author, [
            .runFinished(run: run, outcome: "asked \(questions.count) \(plural)"), .questionsRaised(role: role, questions: questions),
            .flagSet(.needsInput, reason: "\(questions.count) open \(plural) from the \(role.title)")])
        await tracker.comment(on: node.ticket, """
            \(Self.needsInputMarker): the \(role.title) can't go on without answers.
            \(Self.numbered(questions))
            Answer in a comment, then add harness:retry.
            """)
        return "\(node.ticket) needs input: \(questions.count) \(plural) from the \(role.title)"
    }

    static func numbered(_ items: [String]) -> String {
        items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
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
            let task = await makeTask(node, run: run, in: directory, log: agentLog(node, run))
            try await watchingUserGitState(node, run: run) { try await team.implementer.implement(task) }
            guard let commit = try await workspace.commitAll(in: directory, message: "\(node.spec.id): \(node.spec.title)", author: run)
            else { throw AgentFailure("submitted no changes") }
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "submitted"), .changeSubmitted(run: run, commit: commit), .phaseChanged(to: .checking)])
            return "\(node.ticket) implemented by \(run) → Checking"
        } catch let error as UserGitStateChanged {
            // Not something another attempt fixes: a human checks what happened to their repo first.
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed"), .attemptFailed(summary: "\(error)"), .phaseChanged(to: .ready),
                .flagSet(.escalated, reason: "\(error)")])
            await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(error)\nWhen checked, add label harness:retry.")
            return "\(node.ticket) escalated: \(error)"
        } catch {
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed"), .attemptFailed(summary: "\(error)"), .phaseChanged(to: .ready)])
            return try await escalateIfNeeded(node.id) ?? "\(node.ticket) implementer failed (\(error)); will retry"
        }
    }

    /// Fast feedback on the leaf's own branch: only its own acceptance tests (doc 08 §4, layer 2).
    private func preCheck(_ node: NodeState) async throws -> String {
        guard let submission = node.lastSubmission else { return "\(node.ticket): nothing submitted" }
        let run = Self.newRunID()
        let directory = workspace.worktree(for: node.id)
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .verifier)], expecting: node.version)

        var output: CheckOutput
        if let tampered = try await protectedTestsViolation(node, in: directory) {
            output = CheckOutput(passed: false, summary: tampered, log: tampered)
        } else {
            try await workspace.prepareBuild(in: directory)
            output = await checks.runChecks(in: directory, only: node.spec.testTarget)
        }
        let evidence = try makeEvidence(node, check: "own acceptance tests on branch", output: output,
                                        builtBy: submission.run, checkedBy: run, commit: submission.commit)
        try await write(node.id, by: .agent(run: run, role: .verifier), [
            .evidenceRecorded(evidence), .runFinished(run: run, outcome: output.passed ? "passed" : "failed"),
            .phaseChanged(to: output.passed ? .landing : .ready)])
        if output.passed { return "\(node.ticket) pre-checked by \(run) → Landing queue" }
        await tracker.comment(on: node.ticket, "🔁 Pre-check failed: \(output.summary)")
        return try await escalateIfNeeded(node.id) ?? "\(node.ticket) failed pre-check; will retry"
    }

    /// The landing queue (doc 08 §4, layer 3): rebase onto the latest main, run ALL tests (own + every proven
    /// node's), and only then merge. A leaf is proven only once it has landed.
    private func land(_ node: NodeState) async throws -> String {
        guard let submission = node.lastSubmission else { return "\(node.ticket): nothing to land" }
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
            return try await escalateIfNeeded(node.id) ?? "\(node.ticket) conflicted at landing → rework"
        }

        // 2. Re-check everything on top of the latest main.
        var output: CheckOutput
        if let tampered = try await protectedTestsViolation(node, in: directory) {
            output = CheckOutput(passed: false, summary: tampered, log: tampered)
        } else {
            try await workspace.prepareBuild(in: directory)
            output = await checks.runChecks(in: directory, only: nil)
        }
        let candidate = try await workspace.head(of: directory)
        let evidence = try makeEvidence(node, check: "all tests on latest main (landing)", output: output,
                                        builtBy: submission.run, checkedBy: run, commit: candidate)

        // 3. Merge.
        if output.passed {
            let main = try await workspace.landOnMain(node.id)
            try await write(node.id, by: checker, [
                .evidenceRecorded(evidence), .landed(commit: main), .runFinished(run: run, outcome: "landed"),
                .phaseChanged(to: .proven)])
            try? await workspace.removeWorktree(for: node.id)
            await tracker.comment(on: node.ticket, "🛬 Landed on main at \(main.prefix(8)) with all tests passing.")
            return "\(node.ticket) landed by \(run) → Proven"
        }

        // Which node's behaviour broke? Someone else's → two requirements may contradict (doc 08 §5).
        let state = await ledger.workingState()
        let broken = output.failingTargets.subtracting([node.spec.testTarget])
            .compactMap { target in state.nodes.values.first { $0.spec.testTarget == target && $0.phase == .proven } }
        var kinds: [EventKind] = [.evidenceRecorded(evidence), .runFinished(run: run, outcome: "failed"), .phaseChanged(to: .ready)]
        if !broken.isEmpty && !output.failingTargets.contains(node.spec.testTarget) {
            let names = broken.map { "\($0.ticket) (\($0.spec.title))" }.joined(separator: ", ")
            let reason = "Requirements conflict: this change breaks proven behaviour of \(names). A human must decide which requirement wins."
            kinds.append(.flagSet(.escalated, reason: reason))
            try await write(node.id, by: checker, kinds)
            await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(reason)")
            for other in broken {
                await tracker.comment(on: other.ticket, "ℹ️ \(node.ticket) (\(node.spec.title)) contradicts this ticket's acceptance criteria. Escalated there.")
            }
            return "\(node.ticket) breaks \(broken.map(\.ticket).joined(separator: ", ")) → requirements conflict, escalated"
        }
        try await write(node.id, by: checker, kinds)
        await tracker.comment(on: node.ticket, "🔁 Landing check failed on the latest main: \(output.summary)")
        return try await escalateIfNeeded(node.id) ?? "\(node.ticket) failed at landing; will retry"
    }

    // MARK: Helpers

    private func escalateIfNeeded(_ id: NodeID) async throws -> String? {
        guard let node = await ledger.workingState().nodes[id], let reason = policy.escalationReason(for: node) else { return nil }
        try await write(id, by: .reconciler, [.flagSet(.escalated, reason: reason)])
        await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(reason)\nWhen fixed, add label harness:retry.")
        return "\(node.ticket) escalated: \(reason)"
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
        var seen = Set<String>()
        return wanted.filter { seen.insert($0).inserted }.filter { ref in
            if state.resolvedExternal.contains(ref) { return false }
            let here = state.nodes[ref] ?? state.node(forTicket: ref)
            return here?.phase != .proven
        }
    }

    private func propose(_ spec: NodeSpec, clarifications: [Clarification], log: URL?) async throws -> Breakdown {
        try await team.decomposer.proposeChildren(BreakdownRequest(
            spec: spec, existingComponents: workspace.existingComponents(), clarifications: clarifications,
            guesswork: policy.guesswork, log: log))
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
        agentRuns[run] = AgentRunSpan(ticket: node.ticket, start: clock)
        defer {
            clock += 1
            agentRuns[run]?.end = clock
        }
        let before = try await workspace.userGitState()
        let result = try await agent()
        let after = try await workspace.userGitState()
        guard after != before, let mine = agentRuns[run] else { return result }
        let changed = Set(before).symmetricDifference(after).compactMap { $0.split(separator: " ").last.map(String.init) }
        let alongside = agentRuns.filter { $0.key != run && $0.value.start <= clock && ($0.value.end ?? .max) > mine.start }
            .map(\.value.ticket)
        throw UserGitStateChanged(names: Array(Set(changed)).sorted(), alongside: Array(Set(alongside)).sorted())
    }

    private struct AgentRunSpan {
        let ticket: String
        let start: Int
        var end: Int?
    }

    private func makeTask(_ node: NodeState, run: RunID, in directory: URL, log: URL?) async -> AgentTask {
        let labels = await tracker.ticket(node.ticket)?.labels.map(\.name) ?? []
        let state = await ledger.workingState()
        return AgentTask(
            spec: node.spec, run: run, directory: directory, testFolder: workspace.testFolder(for: node.spec),
            context: workspace.agentContext, attempt: node.failedAttempts + 1,
            previousFailure: node.recentFailures.last, simulationHints: Set(labels.filter { $0.hasPrefix("sim:") }), log: log,
            clarifications: state.clarifications(for: node.id), guesswork: policy.guesswork)
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
                              commit: String) throws -> Evidence {
        let artifact = try artifacts.put(named: "\(node.id)-\(checkedBy).log", contents: Data(output.log.utf8))
        return Evidence(check: check, passed: output.passed, summary: output.summary, specHash: node.spec.specHash,
                        builtBy: builtBy, checkedBy: checkedBy, artifactPath: artifact.path, artifactSHA256: artifact.sha256,
                        commit: commit)
    }

    private func projectStatuses() async {
        let state = await ledger.workingState()
        for node in state.nodes.values {
            await tracker.setStatus(of: node.ticket, to: state.status(of: node))
        }
    }

    private func write(_ node: NodeID?, by who: Participant, _ kinds: [EventKind], expecting version: Int? = nil) async throws {
        let events = kinds.map { LedgerEvent(node: node, by: who, kind: $0) }
        let expecting = node.flatMap { id in version.map { [id: $0] } } ?? [:]
        try await ledger.append(events, expecting: expecting)
    }

    static func newRunID() -> RunID { "run-" + UUID().uuidString.prefix(6).lowercased() }
}
