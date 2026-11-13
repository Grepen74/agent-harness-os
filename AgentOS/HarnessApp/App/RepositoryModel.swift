import AgentOSAdapters
import AgentOSCore
import AgentOSUI
import AppKit
import Observation

/// The harness on one real repo: the read-only readiness scan, the repo's config and effective policy, the
/// baseline, the repo's tracker (local, or GitHub Issues when its config says so) and, once nothing blocks it, Copilot agents working through a `RepositorySession`.
/// Everything is recorded in the repo's own ledger, outside the repo (see `RepositoryStorage`).
@Observable @MainActor
final class RepositoryModel: HarnessActions {
    let url: URL
    let view = HarnessViewModel()
    private(set) var root: URL?
    private(set) var storage: URL?
    /// The harness's limits (Settings window); a change means a rescan.
    var harness = HarnessSettings()
    /// Why agents can't start: the scan's blockers, or a missing Copilot CLI. Empty when a session is ready.
    private(set) var startBlockers: [String] = ["Scanning…"]
    var isRunning = false
    var isBusy = false
    /// Shown only for rounds that take noticeable time.
    var showsActivity = false
    var canWork: Bool { session != nil }
    @ObservationIgnored private var location: RepositoryLocation?
    /// Settings changed while a scan was running.
    @ObservationIgnored private var rescanAgain = false
    @ObservationIgnored private var ledger: Ledger?
    @ObservationIgnored private var tracker: (any TicketBoard)?
    /// What `tracker` was made for: the scan's choice and the GitHub account from Settings.
    @ObservationIgnored private var trackerMadeFor: (choice: TrackerChoice, account: String?)?
    @ObservationIgnored private var session: RepositorySession?
    @ObservationIgnored private var recovered = false
    @ObservationIgnored private var isClosed = false
    /// Owns Run and the session's agents across rounds: pausing, draining before a new session, closing.
    @ObservationIgnored private let lifecycle = HarnessLifecycleController(session: nil)
    @ObservationIgnored private let scanner = ReadinessScanner()
    @ObservationIgnored private let follower = LedgerFollower()

    init(url: URL) {
        self.url = url
        view.actions = self
        view.you = NSUserName()
        HarnessLifecycle.repositories.add(self)
        lifecycle.runStep = { [weak self] in await self?.step() }
    }

    var name: String { (root ?? url).lastPathComponent }
    private var human: Participant { .human(view.you.isEmpty ? NSUserName() : view.you) }

    func rescan() async {
        guard !isClosed else { return }
        guard !view.isScanning else {
            rescanAgain = true
            return
        }
        view.isScanning = true
        await scanOnce()
        while rescanAgain {
            rescanAgain = false
            await scanOnce()
        }
        view.isScanning = false
    }

    private func scanOnce() async {
        let location: RepositoryLocation
        switch await scanner.locate(url) {
        case .blocked(let result):
            root = result.root
            show(result)
            startBlockers = RepositorySession.blockers(result.scan)
            log("Scanned \(url.path): \(result.scan.summary). Not recorded: no repo to record it for.")
            return
        case .repo(let found):
            location = found
        }
        self.location = location
        root = location.root
        do {
            let ledger = try openLedger(location.identity)
            if !recovered {
                let notes = try await RepositorySession.recoverInterruptedRuns(in: ledger)
                recovered = true
                view.activity.insert(contentsOf: notes, at: 0)
            }
            let result = await scanner.scan(location, harness: harness, baseline: await ledger.workingState().baseline)
            show(result)
            useTracker(result.tracker)
            let recorded = try await ledger.record(result.scan)
            log("Scanned: \(result.scan.summary). " + (recorded ? "Recorded in the ledger." : "Same as the last recorded scan."))
            await startSession(result, at: location, ledger: ledger)
            await refresh()
        } catch {
            log("⛔️ Couldn't record the scan: \(error)")
        }
    }

    /// A new session for every scan, so agents always work with the current config and policy. The old session's
    /// round and agents (including those started by earlier rounds) finish first; Run continues with the new one.
    private func startSession(_ result: ScannedRepository, at location: RepositoryLocation, ledger: Ledger) async {
        guard !isClosed else { return }
        let wasRunning = isRunning
        if let running = await session?.reconciler.busyNodes, !running.isEmpty {
            log("Waiting for the agents on \(running.sorted().joined(separator: ", ")) to finish before using the new scan…")
        }
        do {
            try await lifecycle.replaceSession { [self] in
                session = nil
                guard !isClosed, let storage else { return nil }
                var blockers = RepositorySession.blockers(result.scan)
                let copilot = CopilotCLI.locate()
                if copilot == nil { blockers.append("Copilot CLI not found") }
                guard blockers.isEmpty, let config = result.config, let copilot else {
                    startBlockers = blockers
                    return nil
                }
                session = try RepositorySession(
                    location: location, storage: storage, ledger: ledger, config: config, policy: result.policy,
                    team: RepositorySession.copilotTeam(executable: copilot, policy: result.policy), tracker: tracker)
                startBlockers = []
                return session
            }
        } catch {
            startBlockers = ["Couldn't prepare the workspace: \(error)"]
        }
        isRunning = false
        if wasRunning { setRunning(true) }
    }

    // MARK: Agents

    /// One reconciler round. It returns without waiting for the agents it starts.
    func step() async {
        guard !isBusy, session != nil else { return }
        isBusy = true
        let indicator = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { showsActivity = true }
        }
        let report = await lifecycle.step()
        indicator.cancel()
        showsActivity = false
        isBusy = false
        if let stop = report.safeStop {
            log("⛔️ \(stop)")
            setRunning(false)
        }
        for action in report.actions { log(action) }
        await refresh()
    }

    /// Run = a round about every 2 seconds while the window is open. Pause leaves running agents working.
    func setRunning(_ running: Bool) {
        lifecycle.setRunning(running)
        isRunning = lifecycle.isRunning
    }

    /// The window closed: stop Run and stop following the ledger.
    func close() async {
        await shutdown(reason: "repository window closed")
        follower.stop()
    }

    /// Stops the agents (recording `reason` on their runs) and waits for their cleanup.
    func shutdown(reason: String) async {
        isClosed = true
        await lifecycle.shutdown(reason: reason)
        isRunning = false
        await refresh()
    }

    func stopRun(node: NodeID, run: RunID, by person: String) async {
        guard let session, await session.ledger.workingState().nodes[node]?.activeRun?.run == run else { return }
        do { try await session.reconciler.stopRun(run, by: person) }
        catch { log("Couldn't stop \(run): \(error)") }
        await refresh()
    }

    /// Stops Run and waits for a round already under way and for every agent the session started.
    func stopAndWait() async {
        await lifecycle.stopAndWait()
        isRunning = false
    }

    // MARK: Baseline and ledger

    func runBaseline() async {
        guard !view.isRunningBaseline, let location, let config = view.config, let storage, let ledger else { return }
        view.isRunningBaseline = true
        log("Running the baseline on \(location.branch) at \(location.commit.prefix(8))…")
        let baseline = await BaselineRunner(storage: storage).run(config: config, commit: location.commit, repo: location.root)
        do {
            try await ledger.record(baseline)
            log("Baseline \(baseline.passed ? "passed" : "FAILED") in \(baseline.seconds)s: \(baseline.summary)")
        } catch {
            log("⛔️ Couldn't record the baseline: \(error)")
        }
        view.isRunningBaseline = false
        await rescan()
    }

    func verifyChain() async { view.chain = await ledger?.verifyChain() }

    func open(_ path: String) { NSWorkspace.shared.open(URL(filePath: path)) }

    func openRepoConfig() {
        guard let root else { return }
        view.openRepoConfig(prepare: { draft in
            let (file, created) = try RepoConfigFile.prepare(in: root, draft: draft)
            if created {
                log("Wrote \(draft == nil ? "an empty" : "the draft") \(RepoConfig.path) in your checkout. "
                    + "Commit it on \(location?.branch ?? "the default branch"), then rescan.")
            }
            return file
        }, open: { file in
            NSWorkspace.shared.open(file)
        })
        if let error = view.repoConfigFileError {
            log("⛔️ \(error)")
        }
    }

    // MARK: Watching agents work

    func worktree(of node: NodeID) -> URL? { session.flatMap { WorkingCopy.existing($0.workspace.worktree(for: node)) } }

    func agentLog(of node: NodeID, run: RunID) -> URL? {
        session.flatMap { WorkingCopy.agentLog(in: $0.workspace.artifactsDirectory, node: node, run: run) }
    }

    func changes(of node: NodeID) async -> String {
        guard let session else { return "No session: agents can't run on this repo right now." }
        do { return try await session.workspace.changes(for: node) } catch { return "Couldn't read the changes: \(error)" }
    }

    func reveal(_ url: URL) { WorkingCopy.reveal(url) }
    func openInXcode(_ url: URL) { WorkingCopy.openInXcode(url) }

    func revealRepository() { NSWorkspace.shared.activateFileViewerSelecting([root ?? url]) }

    func revealStorage() {
        guard let storage else { return }
        NSWorkspace.shared.activateFileViewerSelecting([storage])
    }

    private func openLedger(_ identity: String) throws -> Ledger {
        if let ledger { return ledger }
        let ledger = try Ledger(store: RepositoryStorage.ledgerStore(for: identity))
        let storage = RepositoryStorage.directory(for: identity)
        self.ledger = ledger
        self.storage = storage
        useTracker(.local)
        follower.follow(ledger) { [weak self] in await self?.refresh() }
        return ledger
    }

    /// The same tracker across scans (a session per scan), replaced only when the config or account changes.
    private func useTracker(_ choice: TrackerChoice) {
        guard let storage else { return }
        let account = harness.githubAccount
        if let made = trackerMadeFor, made.choice == choice, made.account == account { return }
        tracker = RepositorySession.tracker(choice, storage: storage, githubAccount: account)
        trackerMadeFor = (choice, account)
        if let tracker { log("Tickets: \(tracker.name)") }
    }

    private func show(_ result: ScannedRepository) {
        view.readiness = result.scan
        view.policy = result.policy
        view.config = result.config
        view.signals = HarnessCommand.allCases.filter(result.policy.policy.allowedSignals.contains)
        view.configDraft = result.draft
    }

    private func refresh() async {
        if let tracker {
            view.tickets = await tracker.tickets()
            for problem in await tracker.takeProblems() { log("⚠️ Tracker: \(problem)") }
        }
        guard let ledger else { return }
        view.records = await ledger.allRecords()
        view.state = await ledger.workingState()
    }

    private func log(_ message: String) {
        view.activity.insert("\(Date.now.formatted(date: .omitted, time: .standard))  \(message)", at: 0)
        view.activity = Array(view.activity.prefix(300))
    }

    // MARK: The tracker (local: private to this Mac, outside the repo; or the repo's GitHub issues)

    func addLabel(_ name: String, to key: String) async { await tracker?.addLabel(name, to: key, by: human); await refresh() }
    func removeLabel(_ name: String, from key: String) async { await tracker?.removeLabel(name, from: key); await refresh() }
    func comment(_ text: String, on key: String) async { await tracker?.addComment(text, to: key, by: human); await refresh() }

    func createTicket(title: String, description: String, criteria: [String], blockedBy: [String]) async {
        _ = await tracker?.newTicket(title: title, description: description, acceptanceCriteria: criteria,
                                     blockedBy: blockedBy, by: human)
        await refresh()
    }

    func edit(_ key: String, title: String, description: String, criteria: [String], blockedBy: [String]) async {
        await tracker?.edit(key, title: title, description: description, acceptanceCriteria: criteria, blockedBy: blockedBy)
        await refresh()
    }
}
