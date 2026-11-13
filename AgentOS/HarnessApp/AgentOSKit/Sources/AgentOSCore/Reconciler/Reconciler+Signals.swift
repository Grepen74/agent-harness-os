import Foundation

extension Reconciler {
    // MARK: Intake: signals from people, news from other systems

    struct Rejection: Error { let reason: String }

    func intakeSignals(_ report: inout RoundReport) async {
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
}
