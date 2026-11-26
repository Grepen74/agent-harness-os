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
    /// Only a missing or old baseline keeps agents from starting, so Run can run the baseline first.
    private(set) var canRunAfterBaseline = false
    @ObservationIgnored private var location: RepositoryLocation?
    /// Settings changed while a scan was running.
    @ObservationIgnored private var rescanAgain = false
    /// Start Run once the scans under way (and any they queued) have finished, if nothing blocks agents then.
    @ObservationIgnored private var startAfterRescan = false
    @ObservationIgnored private var ledger: Ledger?
    /// Keeps other windows and app copies from writing this repo's ledger while this window has it open.
    @ObservationIgnored private var storageLock: StorageLock?
    @ObservationIgnored private var ledgerSession: HarnessLedgerSession?
    @ObservationIgnored private var tracker: (any TicketBoard)?
    /// What `tracker` was made for: the scan's choice and the GitHub account from Settings.
    @ObservationIgnored private var trackerMadeFor: (choice: TrackerChoice, account: String?)?
    @ObservationIgnored private var session: RepositorySession?
    @ObservationIgnored private var recovered = false
    /// A scan is under way (until its session has started and tickets are read); `view.isScanning` only covers the
    /// readiness scan itself, so the findings don't wait for GitHub.
    @ObservationIgnored private var scanInProgress = false
    @ObservationIgnored private var isClosed = false
    /// Owns Run and the session's agents across rounds: pausing, draining before a new session, closing.
    @ObservationIgnored private let lifecycle = HarnessLifecycleController(session: nil)
    @ObservationIgnored private let scanner = ReadinessScanner()
    @ObservationIgnored private let follower = LedgerFollower()

    init(url: URL) {
        self.url = url
        view.actions = self
        view.offersLedgerCutBack = true
        view.you = NSUserName()
        HarnessLifecycle.repositories.add(self)
        lifecycle.runStep = { [weak self] in await self?.step() }
    }

    var name: String { (root ?? url).lastPathComponent }
    private var human: Participant { .human(view.you.isEmpty ? NSUserName() : view.you) }

    func rescan() async {
        guard !isClosed else { return }
        guard !scanInProgress else {
            rescanAgain = true
            return
        }
        scanInProgress = true
        await scanOnce()
        while rescanAgain {
            rescanAgain = false
            await scanOnce()
        }
        scanInProgress = false
        view.isScanning = false
        if startAfterRescan {
            startAfterRescan = false
            if canWork { setRunning(true) }
            else { log("Not starting the agents: " + startBlockers.joined(separator: "; ")) }
        }
        // Outside the scan guard: tickets and history that are slow to read don't hold up the next scan or Run.
        await refresh()
    }

    private func scanOnce() async {
        view.isScanning = true
        defer { view.isScanning = false }
        let location: RepositoryLocation
        switch await scanner.locate(url) {
        case .blocked(let result):
            root = result.root
            view.isScanning = false
            show(result)
            startBlockers = RepositorySession.blockers(result.scan)
            canRunAfterBaseline = false
            log("Scanned \(url.path): \(result.scan.summary). Not recorded: no repo to record it for.")
            return
        case .repo(let found):
            location = found
        }
        self.location = location
        root = location.root
        do {
            let ledger = try await openLedger(location.identity)
            let chainProblem = await ledger.chainProblem()?.problem
            if !recovered, chainProblem == nil {
                let notes = try await RepositorySession.recoverInterruptedRuns(in: ledger)
                recovered = true
                view.activity.insert(contentsOf: notes, at: 0)
            }
            let baseline = await ledger.workingState().baseline
            let result = await scanner.scan(location, harness: harness, baseline: baseline)
            view.isScanning = false
            show(result)
            useTracker(result.tracker)
            guard !isClosed else { return }
            if chainProblem == nil {
                let recorded = try await ledger.record(result.scan)
                log("Scanned: \(result.scan.summary). " + (recorded ? "Recorded in the ledger." : "Same as the last recorded scan."))
            } else {
                log("Scanned: \(result.scan.summary). Not recorded: the ledger's chain is broken.")
            }
            await startSession(result, baseline: baseline, at: location, ledger: ledger)
        } catch let busy as StorageLock.Busy {
            startBlockers = [busy.description]
            canRunAfterBaseline = false
            log("⛔️ \(busy)")
        } catch {
            if ledger == nil {
                startBlockers = ["Couldn't open the ledger: \(error)"]
                canRunAfterBaseline = false
            }
            log("⛔️ Couldn't record the scan: \(error)")
        }
    }

    /// A new session for every scan, so agents always work with the current config and policy. The old session's
    /// round and agents (including those started by earlier rounds) finish first; Run continues with the new one.
    private func startSession(_ result: ScannedRepository, baseline: Baseline?, at location: RepositoryLocation,
                              ledger: Ledger) async {
        guard !isClosed else { return }
        let wasRunning = isRunning
        let chainBlocker = await ledger.chainProblem()?.problem.map {
            "The ledger's chain is broken at #\($0.position): cut it back in the Ledger pane"
        }
        if let running = await session?.reconciler.busyNodes, !running.isEmpty {
            log("Waiting for the agents on \(running.sorted().joined(separator: ", ")) to finish before using the new scan…")
        }
        do {
            try await lifecycle.replaceSession { [self] in
                session = nil
                canRunAfterBaseline = false
                guard !isClosed, let storage else { return nil }
                var blockers = RepositorySession.blockers(result.scan)
                let copilot = CopilotCLI.locate()
                if copilot == nil { blockers.append("Copilot CLI not found") }
                if let chainBlocker { blockers.append(chainBlocker) }
                guard blockers.isEmpty, let config = result.config, let copilot else {
                    startBlockers = blockers
                    canRunAfterBaseline = copilot != nil && result.config != nil && chainBlocker == nil
                        && RepositorySession.onlyBaselineBlocks(result.scan, baseline: baseline)
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
            canRunAfterBaseline = false
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
        view.unrecordedSafeStop = report.safeStop
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
        // Writes already handed to the ledger finish before another window may open it.
        _ = await ledger?.chainProblem()
        storageLock?.release()
        storageLock = nil
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

    func stopPreview(run: RunID, by person: String) async {
        guard let session, await session.ledger.workingState().runningPreviews.values.contains(where: { $0.run == run })
        else { return }
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
        guard await recordBaseline() else { return }
        await rescan()
    }

    /// Run when only a missing or old baseline blocks agents: the baseline, a rescan, then Run if nothing blocks.
    func runBaselineThenStart() async {
        guard canRunAfterBaseline, await recordBaseline() else { return }
        startAfterRescan = true
        await rescan()
    }

    /// Runs the baseline on the scanned commit and records it; false if it couldn't start.
    private func recordBaseline() async -> Bool {
        guard !view.isRunningBaseline, let location, let config = view.config, let storage, let ledger else { return false }
        view.isRunningBaseline = true
        log("Running the baseline on \(location.branch) at \(location.commit.prefix(8))…")
        let baseline = await BaselineRunner(storage: storage).run(config: config, commit: location.commit, repo: location.root)
        guard !isClosed else { return false }
        do {
            try await ledger.record(baseline)
            log("Baseline \(baseline.passed ? "passed" : "FAILED") in \(baseline.seconds)s: \(baseline.summary)")
        } catch {
            log("⛔️ Couldn't record the baseline: \(error)")
        }
        view.isRunningBaseline = false
        return true
    }

    func verifyChain() async { view.chain = await ledger?.verifyChain() }

    /// A person's repair of a broken ledger (Ledger pane, after confirming): Run stops, the records from the break
    /// on move, unchanged, to a file beside the ledger, the ledger reopens on its intact part with the cut recorded,
    /// and the repo is scanned again.
    func cutBackLedger() async {
        guard let location, storageLock != nil, !isClosed else { return }
        await stopAndWait()
        let store = RepositoryStorage.ledgerStore(for: location.identity)
        let cut: LedgerCutBack?
        do {
            // Without a ledger (its file couldn't be read) nothing in this window appends; the storage lock keeps
            // other windows out.
            if let ledger { cut = try await ledger.exclusively { try store.cutBackToIntactPart() } }
            else { cut = try store.cutBackToIntactPart() }
        } catch {
            log("⛔️ Couldn't cut the ledger back: \(error)")
            return
        }
        guard let cut else {
            log("The ledger file is intact: nothing to cut back.")
            return await verifyChain()
        }
        do {
            let reopened = try Ledger(store: store)
            try await reopened.append([LedgerEvent(node: nil, by: human, kind: .ledgerCutBack(
                keptRecords: cut.keptRecords, movedRecords: cut.movedRecords, movedTo: cut.movedTo.lastPathComponent))])
            // The tracker remembers observations from the old ledger and would write them back into the new one.
            tracker = nil
            trackerMadeFor = nil
            recovered = false
            adopt(reopened, identity: location.identity)
            await ledgerSession?.restore(from: reopened)
            view.chain = await reopened.verifyChain()
            log("🧑‍🔧 Ledger cut back to its \(cut.keptRecords) intact records; \(cut.movedRecords) moved to "
                + "\(cut.movedTo.lastPathComponent).")
        } catch {
            log("⛔️ Couldn't reopen the ledger after cutting it back: \(error)")
            return
        }
        await rescan()
    }

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

    private func openLedger(_ identity: String) async throws -> Ledger {
        if let ledger { return ledger }
        if storageLock == nil { storageLock = try RepositoryStorage.lock(for: identity) }
        storage = RepositoryStorage.directory(for: identity)
        let ledger: Ledger
        do {
            ledger = try Ledger(store: RepositoryStorage.ledgerStore(for: identity))
        } catch {
            // An unreadable line: the Ledger pane offers cutting the file back to the records before it.
            view.chain = ChainReport(checked: 0, problem: .init(position: 0, reason: "\(error)"))
            view.unrecordedSafeStop = "The ledger can't be read (\(error)). Cut it back in the Ledger pane."
            throw error
        }
        adopt(ledger, identity: identity)
        if let report = await ledger.chainProblem(), let problem = report.problem {
            view.chain = report
            view.unrecordedSafeStop = Reconciler.integritySafeStop(problem)
            log("⛔️ \(Reconciler.integritySafeStop(problem))")
        }
        return ledger
    }

    /// Makes `ledger` this window's ledger: history, the local tracker until a scan picks one, following its appends.
    private func adopt(_ ledger: Ledger, identity: String) {
        self.ledger = ledger
        if ledgerSession == nil { ledgerSession = HarnessLedgerSession(view: view, source: ledger) }
        useTracker(.local)
        follower.follow(ledger) { [weak self] in await self?.refresh() }
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
        await ledgerSession?.refresh()
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
