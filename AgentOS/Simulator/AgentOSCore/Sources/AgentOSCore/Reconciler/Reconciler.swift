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
/// - Steps run one after another; production hands them to many agents in parallel. Leaves still work
///   in parallel in the sense that matters for conflicts: each on its own branch, unaware of the others.
/// - It runs when asked (Step / Run in the app); production is an always-on service woken by events
///   plus a regular full check, with one leader per system and fencing tokens.
/// - Claims don't time out while running; after a restart, unfinished runs are treated as expired.
public actor Reconciler {
    let ledger: Ledger
    let tracker: any TrackerAdapter
    let external: any ExternalDependencySource
    let workspace: Workspace
    let checks: any CheckRunner
    let policy: Policy
    public private(set) var team: AgentTeam

    public init(ledger: Ledger, tracker: any TrackerAdapter, external: any ExternalDependencySource,
                workspace: Workspace, checks: any CheckRunner, team: AgentTeam, policy: Policy = Policy()) {
        self.ledger = ledger
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

        for id in await ledger.workingState().creationOrder {
            let state = await ledger.workingState()
            guard let node = state.nodes[id] else { continue }
            do {
                if let action = try await advance(node, in: state) { report.actions.append(action) }
            } catch LedgerError.conflict {
                continue // The node changed meanwhile; the next round sees the new state.
            } catch {
                report.actions.append("⚠️ \(node.ticket): \(error)")
            }
        }

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
                await tracker.consume(signal, reply: "❌ \(signal.command.label): \(rejection.reason)")
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

        switch signal.command {
        case .preview:
            // A preview does NOT adopt the ticket and creates nothing (doc 05 §3).
            let problems = policy.readinessProblems(ticket)
            guard problems.isEmpty else { throw Rejection(reason: "Not ready yet. Missing: \(problems.joined(separator: ", ")).") }
            let spec = Planner.rootSpec(for: ticket)
            let children = Planner.childSpecs(parent: spec, proposals: try await propose(spec))
            let number = (state.previews[ticket.key]?.number ?? 0) + 1
            try await write(nil, by: .reconciler, [
                .previewRecorded(ticket: ticket.key, number: number, specHash: spec.specHash, proposal: children)])
            await tracker.comment(on: ticket.key, """
                🔍 Preview #\(number). Nothing has been created.
                \(Planner.describe(children, under: ticket.title))
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
            guard !node.gates.contains(.build) else { throw Rejection(reason: "Build is already approved.") }
            try await write(node.id, by: .human(person), [.gateOpened(.build)])
            return "build approved for \(node.spec.id) and everything below it"

        case .retry:
            guard let node, node.flags[.escalated] != nil else { throw Rejection(reason: "Nothing to retry: not escalated.") }
            try await write(node.id, by: .human(person), [.flagCleared(.escalated), .attemptsReset])
            return "escalation cleared; attempts reset"

        case .go:
            // Both gates at once: the readiness checks for both run now, so nothing stops halfway for lack
            // of permission. Production: also checks the build budget is set (doc 05 §5).
            if let node {
                let missing = [Gate.breakdown, .build].filter { !node.gates.contains($0) }
                guard !missing.isEmpty else { throw Rejection(reason: "Breakdown and build are already approved.") }
                try await write(node.id, by: .human(person), missing.map { .gateOpened($0) })
                return "\(missing.map(\.rawValue).joined(separator: " and ")) approved for \(node.spec.id) and everything below it"
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
                await tracker.comment(on: node.ticket, "🔓 Unblocked: everything this needs from other systems is delivered.")
                report.actions.append("\(node.ticket) unblocked")
            }
        }
    }

    // MARK: Controllers: one step per node per round

    private func advance(_ node: NodeState, in state: WorkingState) async throws -> String? {
        guard node.flags[.escalated] == nil, node.activeRun == nil else { return nil }

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
                let reason = "Waiting for \(missing.joined(separator: ", ")) from another system"
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
        let children: [NodeSpec]
        let author: Participant
        if let preview = state.previews[node.ticket], preview.specHash == node.spec.specHash {
            // What you saw is what you get: no regeneration (doc 05 §3).
            children = preview.proposal
            author = .reconciler
        } else {
            let run = Self.newRunID()
            author = .agent(run: run, role: .decomposer)
            try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .decomposer)], expecting: node.version)
            do {
                children = Planner.childSpecs(parent: node.spec, proposals: try await propose(node.spec))
            } catch {
                try await write(node.id, by: author, [
                    .runFinished(run: run, outcome: "failed: \(error)"),
                    .flagSet(.escalated, reason: "Breakdown failed: \(error)")])
                await tracker.comment(on: node.ticket, "⚠️ Needs a human: breakdown failed (\(error)). Fix the ticket, then add harness:retry.")
                return "\(node.ticket) breakdown failed → escalated"
            }
            try await write(node.id, by: author, [.runFinished(run: run, outcome: "proposed \(children.count) children")])
        }

        // Leaf check (doc 02 §4): a "breakdown" into one piece is the node itself, so it becomes the leaf.
        // Production: the decomposer runs the full leaf check before proposing children at all.
        if children.count <= 1 {
            let touches = children.first?.touches ?? [ComponentName.from(node.spec.title, maxWords: 3)]
            let needs = Set(node.spec.dependsOn + (children.first?.dependsOn ?? [])).sorted()
            try await write(node.id, by: author, [.becameLeaf(touches: touches)]
                + needs.map { .linkAdded(TypedLink(from: node.id, type: .dependsOn, to: $0)) })
            await tracker.comment(on: node.ticket, """
                🍃 No breakdown needed: small enough to build as it is (leaf check passed).
                \(Planner.describe(children, under: node.spec.title))
                This ticket gets its own branch and acceptance tests next; then add harness:build.
                """)
            return "\(node.ticket) passed the leaf check: built as one leaf"
        }

        for spec in children {
            let key = await tracker.createChildTicket(parent: node.ticket, spec: spec, by: author)
            let links = spec.dependsOn.map { TypedLink(from: spec.id, type: .dependsOn, to: $0) }
            try await write(spec.id, by: author, [.nodeCreated(spec: spec, ticket: key)] + links.map { .linkAdded($0) })
        }
        try await write(node.id, by: .reconciler, [.phaseChanged(to: .split)])
        await tracker.comment(on: node.ticket, """
            🌳 Broken down. Each leaf gets its own branch and acceptance tests next; then add harness:build.
            \(Planner.describe(children, under: node.spec.title))
            """)
        return "\(node.ticket) broken down into \(children.count) leaves"
    }

    /// Left side of the V: a fresh branch for the leaf, and its acceptance tests as the branch's first commit.
    private func authorTests(_ node: NodeState) async throws -> String {
        let run = Self.newRunID()
        let author = Participant.agent(run: run, role: .testAuthor)
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .testAuthor)], expecting: node.version)
        let directory = try await workspace.createWorktree(for: node.id)
        let task = await makeTask(node, run: run, in: directory)
        do {
            try await team.testAuthor.writeAcceptanceTests(task)
            let outside = try await workspace.changedTestFiles(in: directory).filter { !$0.hasPrefix("Tests/\(node.spec.testTarget)/") }
            let changed = try await workspace.commitAll(in: directory, message: "\(node.spec.id): acceptance tests", author: run)
            guard outside.isEmpty, changed != nil else {
                throw AgentFailure(changed == nil ? "no tests written" : "wrote outside its own test folder: \(outside.joined(separator: ", "))")
            }
        } catch {
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "failed: \(error)"),
                .flagSet(.escalated, reason: "Couldn't write acceptance tests: \(error)")])
            return "\(node.ticket) test authoring failed → escalated"
        }
        try await write(node.id, by: author, [
            .runFinished(run: run, outcome: "acceptance tests committed"), .testsFixed(digest: testsDigest(node, in: directory)),
            .phaseChanged(to: .ready)])
        return "\(node.ticket) acceptance tests written on branch \(Workspace.branch(for: node.id)) → Ready"
    }

    private func build(_ node: NodeState) async throws -> String {
        let run = Self.newRunID()
        let author = Participant.agent(run: run, role: .implementer)
        // Record the claim and intent first; only then start the agent.
        try await write(node.id, by: .reconciler, [.runStarted(run: run, role: .implementer), .phaseChanged(to: .building)],
                        expecting: node.version)
        let directory = workspace.worktree(for: node.id)
        do {
            try workspace.generateManifest(in: directory)
            try await team.implementer.implement(await makeTask(node, run: run, in: directory))
            guard let commit = try await workspace.commitAll(in: directory, message: "\(node.spec.id): \(node.spec.title)", author: run)
            else { throw AgentFailure("submitted no changes") }
            try await write(node.id, by: author, [
                .runFinished(run: run, outcome: "submitted"), .changeSubmitted(run: run, commit: commit), .phaseChanged(to: .checking)])
            return "\(node.ticket) implemented by \(run) → Checking"
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
            try workspace.generateManifest(in: directory)
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
            try workspace.generateManifest(in: directory)
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

    private func unresolvedDependencies(of node: NodeState, in state: WorkingState) -> [String] {
        node.links.filter { $0.type == .dependsOn && !state.resolvedExternal.contains($0.to) }.map(\.to)
    }

    private func propose(_ spec: NodeSpec) async throws -> [ChildProposal] {
        try await team.decomposer.proposeChildren(of: spec, existingComponents: workspace.existingComponents())
    }

    private func makeTask(_ node: NodeState, run: RunID, in directory: URL) async -> AgentTask {
        let labels = await tracker.ticket(node.ticket)?.labels.map(\.name) ?? []
        return AgentTask(
            spec: node.spec, run: run, directory: directory, attempt: node.failedAttempts + 1,
            previousFailure: node.recentFailures.last, simulationHints: Set(labels.filter { $0.hasPrefix("sim:") }))
    }

    private func testsDigest(_ node: NodeState, in directory: URL) -> String {
        Hashing.digest(of: directory.appending(path: "Tests/\(node.spec.testTarget)"))
    }

    /// Acceptance tests are locked: the node's own must match their fingerprint, and the branch may not touch
    /// any other node's tests (the implementer must never "fix" a conflict by editing someone else's tests).
    private func protectedTestsViolation(_ node: NodeState, in directory: URL) async throws -> String? {
        if testsDigest(node, in: directory) != node.testsDigest {
            return "Acceptance tests were changed after they were fixed (not allowed)"
        }
        let others = try await workspace.changedTestFiles(in: directory).filter { !$0.hasPrefix("Tests/\(node.spec.testTarget)/") }
        return others.isEmpty ? nil : "Changed other nodes' tests (not allowed): \(others.joined(separator: ", "))"
    }

    private func makeEvidence(_ node: NodeState, check: String, output: CheckOutput, builtBy: RunID, checkedBy: RunID,
                              commit: String) throws -> Evidence {
        let artifact = try workspace.writeArtifact(named: "\(node.id)-\(checkedBy).log", contents: output.log)
        return Evidence(check: check, passed: output.passed, summary: output.summary, specHash: node.spec.specHash,
                        builtBy: builtBy, checkedBy: checkedBy, artifactPath: artifact.path, artifactSHA256: artifact.sha256,
                        commit: commit)
    }

    private func projectStatuses() async {
        for node in await ledger.workingState().nodes.values {
            await tracker.setStatus(of: node.ticket, to: policy.trackerStatus(for: node))
        }
    }

    private func write(_ node: NodeID?, by who: Participant, _ kinds: [EventKind], expecting version: Int? = nil) async throws {
        let events = kinds.map { LedgerEvent(node: node, by: who, kind: $0) }
        let expecting = node.flatMap { id in version.map { [id: $0] } } ?? [:]
        try await ledger.append(events, expecting: expecting)
    }

    static func newRunID() -> RunID { "run-" + UUID().uuidString.prefix(6).lowercased() }
}
