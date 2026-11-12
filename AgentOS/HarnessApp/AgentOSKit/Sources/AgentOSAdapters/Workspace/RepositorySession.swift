import AgentOSCore
import Foundation

/// The harness at work on one real repo: the same reconciler as the simulator, wired to the repo's workspace,
/// its configured checks, a local tracker and the repo's ledger, all stored outside the repo:
///
///     <storage>/ledger.jsonl     the repo's ledger (scans, baselines and all work)
///     <storage>/tracker.json     the local tracker's tickets
///     <storage>/artifacts/       check logs (evidence files)
///     <storage>/worktrees/       one working copy per leaf (see `RepositoryWorkspace`)
public final class RepositorySession: Sendable {
    public let storage: URL
    public let ledger: Ledger
    public let tracker: any TicketBoard
    public let workspace: RepositoryWorkspace
    public let reconciler: Reconciler
    private let catchUp: CatchUpCoordinator

    public init(location: RepositoryLocation, storage: URL, ledger: Ledger, config: RepoConfig, policy: EffectivePolicy,
                team: AgentTeam, checks: (any CheckRunner)? = nil, tracker: (any TicketBoard)? = nil) throws {
        self.storage = storage
        self.ledger = ledger
        self.tracker = tracker ?? Self.tracker(storage: storage)
        workspace = try RepositoryWorkspace(
            root: location.root, storage: storage, config: config, landingBranch: policy.landingBranch,
            defaultBranch: location.branch, protectedPaths: policy.protectedPaths)
        catchUp = CatchUpCoordinator(workspace: workspace, ledger: ledger, tracker: self.tracker)
        reconciler = Reconciler(
            ledger: ledger, tracker: self.tracker.adapter, external: NoExternalSystem(), workspace: workspace,
            artifacts: FileArtifactStore(directory: workspace.artifactsDirectory),
            checks: checks ?? CommandCheckRunner(config: config, simulators: SimulatorPool(size: policy.maxParallelAgents)),
            team: team, policy: policy.policy,
            acceptanceTestPreflight: SwiftAcceptanceTestPreflight())
    }

    /// The repo's local tracker. Pass one to `init` to keep using it across sessions (e.g. after a policy change).
    public static func tracker(storage: URL) -> LocalTracker {
        LocalTracker(project: "WORK", store: FileTicketStore(fileURL: storage.appending(path: "tracker.json")))
    }

    /// The tracker a scan chose; the local one when that is the choice or GitHub can't be reached.
    public static func tracker(_ choice: TrackerChoice, storage: URL, githubAccount: String?) -> any TicketBoard {
        switch choice {
        case .local:
            return tracker(storage: storage)
        case .githubIssues(let repo, let project):
            guard let gh = GhCLITransport.locate() else { return tracker(storage: storage) }
            return GitHubIssuesTracker(repo: repo, transport: GhCLITransport(executable: gh, account: githubAccount), project: project)
        }
    }

    /// Copilot CLI agents restricted by the effective policy: denied tools, protected paths, a model per role.
    public static func copilotTeam(executable: String, policy: EffectivePolicy) -> AgentTeam {
        .copilot(CopilotCLI(executable: executable, deniedTools: policy.deniedTools, protectedPaths: policy.protectedPaths),
                 models: policy.agentModels)
    }

    /// Why agents may not start on this repo yet: every blocker from the readiness scan (which includes the
    /// config, the policy and the baseline on the current commit).
    public static func blockers(_ scan: ReadinessScan) -> [String] {
        scan.findings.filter { $0.severity == .blocker }.map(\.title)
    }

    /// Ledger-only recovery, before readiness checks can prevent a repository session from starting.
    public static func recoverInterruptedRuns(in ledger: Ledger) async throws -> [String] {
        var notes: [String] = []
        for node in await ledger.workingState().running {
            guard let active = node.activeRun else { continue }
            var kinds: [EventKind] = [
                .runFinished(run: active.run, outcome: "abandoned: harness restarted")
            ]
            if node.phase == .building { kinds.append(.phaseChanged(to: .ready)) }
            do {
                try await ledger.append(kinds.map { LedgerEvent(node: node.id, by: .reconciler, kind: $0) },
                                        expecting: [node.id: node.version])
                notes.append("Reclaimed \(node.displayName) from \(active.run) after restart")
            } catch LedgerError.conflict {
                continue
            }
        }
        return notes
    }

    /// One reconciler round.
    @discardableResult
    public func step() async -> RoundReport {
        var report = await reconciler.runRound()
        if let action = await catchUp.reconcile() {
            report.actions.append(action)
        }
        return report
    }

    public func catchUpStatus() async -> CatchUpStatus {
        await catchUp.status()
    }

    public func catchUpConflictDiff() async throws -> String {
        try await catchUp.conflictDiff()
    }

    public func openCatchUpInTerminal() async throws -> URL {
        try await catchUp.openInTerminal()
    }

    public func retryCatchUp() async {
        _ = await catchUp.reconcile(force: true)
    }

    /// Rounds until nothing more happens without a human (or `maxRounds` is reached).
    @discardableResult
    public func runUntilIdle(maxRounds: Int = 50, onRound: (@Sendable (RoundReport) -> Void)? = nil) async -> [RoundReport] {
        var reports: [RoundReport] = []
        for _ in 0..<maxRounds {
            let report = await step()
            reports.append(report)
            onRound?(report)
            if report.isIdle || report.safeStop != nil { break }
        }
        return reports
    }
}
