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
    let acceptanceTestPreflight: any AcceptanceTestPreflight
    public nonisolated let policy: Policy
    public private(set) var team: AgentTeam
    /// When each agent of the current round started and finished, in steps of `clock`.
    private var agentRuns: [RunID: AgentRunSpan] = [:]
    private var clock = 0

    public init(ledger: Ledger, tracker: any TrackerAdapter, external: any ExternalDependencySource,
                workspace: any Workspace, artifacts: any ArtifactStore, checks: any CheckRunner, team: AgentTeam,
                policy: Policy = Policy(),
                acceptanceTestPreflight: any AcceptanceTestPreflight = SkippedAcceptanceTestPreflight()) {
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
                report.actions.append("⚠️ \(node.displayName): \(error)")
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

        switch signal.command {
        case .preview:
            // A preview does NOT adopt the ticket and creates nothing (doc 05 §3).
            let problems = policy.readinessProblems(ticket)
            guard problems.isEmpty else { throw Rejection(reason: "Not ready yet. Missing: \(problems.joined(separator: ", ")).") }
            let spec = Planner.rootSpec(for: ticket)
            let answers = (node?.clarifications ?? []) + Self.newPreviewAnswers(on: ticket, for: node)
            let breakdown = try await propose(spec, ticketKey: ticket.key, clarifications: answers, log: nil)
            let questions = policy.questions(in: breakdown.report, role: .decomposer)
            guard questions.isEmpty else {
                // Nothing is recorded: answers in comments below this are read by the next preview, and kept
                // once the ticket is adopted (breakdown or go).
                await tracker.comment(on: ticket.key, """
                    \(Self.previewQuestionsMarker):
                    \(Self.numbered(questions))
                    Answer them in a comment (or edit the ticket), then preview again.
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
            if let node, !node.suggestedAnswers.isEmpty {
                return try await correctSuggestion(on: node, ticket: ticket, in: state)
            }
            if let node, node.flags[.needsInput] != nil {
                return try await resume(node, answeredOn: ticket, by: person)
            }
            if let node, let comment = ticket.comments.last, comment.author.isHuman,
               comment.text.firstMatch(of: /^\s*\d+\s*:/) != nil {
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
                let reviews = waitingForReview(under: node.id, in: state)
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

    private func correctSuggestion(on node: NodeState, ticket: Ticket, in state: WorkingState) async throws -> String {
        let guidance = "Identify a current suggestion by number: comment '<number>: <correct answer>', " +
            "then add harness:retry. Old suggestion numbers cannot correct a replacement run."
        guard let (role, suggestions) = node.suggestedAnswers.max(by: { $0.value.reportedAt < $1.value.reportedAt }),
              let comment = ticket.comments.last(where: { $0.author.isHuman && $0.at >= suggestions.reportedAt }) else {
            throw Rejection(reason: guidance)
        }
        let parts = comment.text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let number = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              number > 0, number <= suggestions.questions.count else {
            throw Rejection(reason: guidance)
        }
        let answer = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw Rejection(reason: guidance) }

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
        let kinds: [EventKind] = [
            .questionsAnswered(Clarification(questions: [suggestions.questions[number - 1].question], answer: answer)),
            .replanned(spec: spec),
        ] + Gate.allCases.filter(node.gates.contains).map { .gateOpened($0) }
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
        guard let answer = Self.answer(on: ticket) else {
            throw Rejection(reason: "Answer \(node.openQuestions.isEmpty ? "the review request" : "the questions") above in a comment " +
                "first, then add harness:retry again. To build the tests as they are, add harness:build instead.")
        }
        let isReview = node.openQuestions.isEmpty
        var kinds: [EventKind] = [
            .questionsAnswered(Clarification(
                questions: isReview ? ["Feedback on the acceptance tests"] : node.openQuestions.map(\.question),
                answer: answer
            )),
            .flagCleared(.needsInput)]
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

    /// Human comments after the harness's latest "Needs input" comment, or nil when nobody answered yet.
    static func answer(on ticket: Ticket) -> String? {
        guard let asked = ticket.comments.lastIndex(where: { !$0.author.isHuman && $0.text.contains(needsInputMarker) }) else { return nil }
        let replies = ticket.comments[(asked + 1)...].filter(\.author.isHuman).map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return replies.isEmpty ? nil : replies.joined(separator: "\n\n")
    }

    static let needsInputMarker = "❓ Needs input"
    static let previewQuestionsMarker = "❓ The decomposer has questions before it can propose a breakdown"

    /// Answers to a preview's questions: the human comments after each such question comment (up to the next
    /// one), with the questions it asked. Those the node doesn't have yet.
    static func newPreviewAnswers(on ticket: Ticket, for node: NodeState?) -> [Clarification] {
        var answers: [Clarification] = []
        var asked: [String]?
        var replies: [String] = []
        func flush() {
            if let asked, !replies.isEmpty { answers.append(Clarification(questions: asked, answer: replies.joined(separator: "\n\n"))) }
            replies = []
        }
        for comment in ticket.comments {
            if !comment.author.isHuman && comment.text.contains(previewQuestionsMarker) {
                flush()
                asked = comment.text.split(separator: "\n").compactMap { line in
                    line.firstMatch(of: /^\d+\.\s+(.+)$/).map { String($0.output.1) }
                }
            } else if asked != nil, comment.author.isHuman {
                let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { replies.append(text) }
            }
        }
        flush()
        return answers.filter { !(node?.clarifications.contains($0) ?? false) }
    }

    /// Adopting or approving keeps the answers given to previews, for every agent that works on it later.
    private static func answerEvents(on ticket: Ticket, for node: NodeState?) -> [EventKind] {
        newPreviewAnswers(on: ticket, for: node).map { .questionsAnswered($0) }
    }

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
                report.actions.append("\(node.displayName) unblocked")
            }
        }
    }

    // MARK: Controllers: one step per node per round

    /// One step per node, up to `maxParallelAgents` nodes at a time. The steps interleave only while they wait
    /// (for an agent, a check, git): each node has its own branch and working copy, and every claim is a
    /// compare-and-swap on the node's version. Actions are reported in node order, whatever finished first.
    private func advanceAll(_ report: inout RoundReport) async {
        agentRuns.removeAll()
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

    private func step(_ id: NodeID) async -> String? {
        let state = await ledger.workingState()
        guard let node = state.nodes[id] else { return nil }
        do {
            return try await advance(node, in: state)
        } catch LedgerError.conflict {
            return nil // The node changed meanwhile; the next round sees the new state.
        } catch {
            return "⚠️ \(node.displayName): \(error)"
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
            return "\(node.displayName) proven (all children proven)"

        case (.leaf, .specified):
            guard state.hasGate(.breakdown, at: node.id) || state.hasGate(.build, at: node.id) else { return nil }
            return try await authorTests(node)

        case (.leaf, .ready):
            guard state.hasGate(.build, at: node.id) else { return nil }
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
            spec.id = "wn-\(key)"
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
        let task = await makeTask(node, run: run, in: directory, log: agentLog(node, run), for: .testAuthor)
        let task = await makeTask(node, run: run, in: directory, log: agentLog(node, run), includeComments: false)
        let own = workspace.testFolder(for: node.spec) + "/"
        let report: AgentReport
        do {
            report = try await watchingUserGitState(node, run: run) { try await team.testAuthor.writeAcceptanceTests(task) }
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
                throw AgentFailure(changed == nil ? "no tests written" : "wrote outside its own test folder \(own): \(outside.joined(separator: ", "))")
            }
            testFiles = try await workspace.changedFiles(in: directory).filter { $0.hasPrefix(own) }
        } catch {
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"),
                .flagSet(.escalated, reason: "Couldn't write acceptance tests: \(error)")])
            return "\(node.displayName) test authoring failed → escalated"
        }

        switch await acceptanceTestPreflight.compileTests(
            in: directory,
            testFolder: workspace.testFolder(for: node.spec),
            expectedAPI: report.expectedAPI
        ) {
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
            \(questions.contains { $0.suggestion != nil }
                ? "Accept or correct the suggested answers in a comment, then add harness:retry."
                : "Answer in a comment, then add harness:retry.")
            """)
        return "\(node.displayName) needs input: \(questions.count) \(plural) from the \(role.title)"
    }

    static func numbered(_ items: [AgentQuestion]) -> String {
        items.enumerated().map { index, item in
            let suggestion = item.suggestion.map { "\n   Suggested answer: \($0)" } ?? ""
            return "\(index + 1). \(item.question)\(suggestion)"
        }.joined(separator: "\n")
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
                .runFinished(run: run, outcome: "failed"), .attemptFailed(summary: "\(error)"), .phaseChanged(to: .ready),
                .flagSet(.escalated, reason: "\(error)")])
            await tracker.comment(on: node.ticket, "⚠️ Needs a human: \(error)\nWhen checked, add label harness:retry.")
            return "\(node.displayName) escalated: \(error)"
        } catch {
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed"), .attemptFailed(summary: "\(error)"), .phaseChanged(to: .ready)])
            return try await escalateIfNeeded(node.id) ?? "\(node.displayName) implementer failed (\(error)); will retry"
        }
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
        var evidence = try makeEvidence(node, check: "all tests on latest main (landing)", output: output,
                                        builtBy: submission.run, checkedBy: run, commit: candidate)

        // 3. Merge.
        if output.passed {
            let main = try await workspace.landOnMain(node.id)
            try await write(node.id, by: checker, [
                .evidenceRecorded(evidence), .landed(commit: main), .runFinished(run: run, outcome: "landed"),
                .phaseChanged(to: .proven)])
            try? await workspace.removeWorktree(for: node.id)
            await tracker.comment(on: node.ticket, "🛬 Landed on main at \(main.prefix(8)) with all tests passing.")
            return "\(node.displayName) landed by \(run) → Proven"
        }

        // Which node's behaviour broke? Someone else's → two requirements may contradict (doc 08 §5).
        let state = await ledger.workingState()
        let broken = output.failingTargets.subtracting([node.spec.testTarget])
            .compactMap { target in state.nodes.values.first { $0.spec.testTarget == target && $0.phase == .proven } }
        var kinds: [EventKind] = [.evidenceRecorded(evidence), .runFinished(run: run, outcome: "failed"), .phaseChanged(to: .ready)]
        if !broken.isEmpty && !output.failingTargets.contains(node.spec.testTarget) {
            let names = broken.map { "\($0.displayName) (\($0.spec.title))" }.joined(separator: ", ")
            let reason = "Requirements conflict: this change breaks proven behaviour of \(names). A human must decide which requirement wins."
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
        var seen = Set<String>()
        return wanted.filter { seen.insert($0).inserted }.filter { ref in
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

    private func withScratchDirectory<T>(_ directory: URL, operation: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation()
    }

    private func makeTask(_ node: NodeState, run: RunID, in directory: URL, log: URL?, for role: AgentRole) async -> AgentTask {
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

    private func makeTask(_ node: NodeState, run: RunID, in directory: URL, log: URL?,
                          includeComments: Bool = true) async -> AgentTask {
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
                : node.brokenTestReports.last?.reason
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
        for node in state.nodes.values {
            await tracker.setStatus(of: node.ticket, to: state.status(of: node))
        }
    }

    /// One node's status and its children's (theirs depends on the parent's phase), as soon as it changes:
    /// a round can take as long as its slowest agent or landing check, so waiting for its end left tickets
    /// showing a status from half an hour ago.
    private func projectStatus(of id: NodeID) async {
        let state = await ledger.workingState()
        guard let node = state.nodes[id] else { return }
        for affected in [node] + node.children.compactMap({ state.nodes[$0] }) {
            await tracker.setStatus(of: affected.ticket, to: state.status(of: affected))
        }
    }

    private func write(_ node: NodeID?, by who: Participant, _ kinds: [EventKind], expecting version: Int? = nil) async throws {
        let events = kinds.map { LedgerEvent(node: node, by: who, kind: $0) }
        let expecting = node.flatMap { id in version.map { [id: $0] } } ?? [:]
        try await ledger.append(events, expecting: expecting)
        if let node { await projectStatus(of: node) }
    }

    static func newRunID() -> RunID { "run-" + UUID().uuidString.prefix(6).lowercased() }
}
