import AgentOSAdapters
import AgentOSCore
import AgentOSUI
import AppKit
import Observation

/// The harness on one real repo: the read-only readiness scan, the repo's config and effective policy, and the
/// baseline, all recorded in the repo's own ledger (outside the repo, see `RepositoryStorage`).
/// Tickets and agents come in later phases.
@Observable @MainActor
final class RepositoryModel: HarnessActions {
    let url: URL
    let view = HarnessViewModel()
    private(set) var root: URL?
    private(set) var storage: URL?
    /// The harness's limits (Settings window); a change means a rescan.
    var harness = HarnessSettings()
    @ObservationIgnored private var location: RepositoryLocation?
    /// Settings changed while a scan was running.
    @ObservationIgnored private var rescanAgain = false
    @ObservationIgnored private var ledger: Ledger?
    @ObservationIgnored private let scanner = ReadinessScanner()

    init(url: URL) {
        self.url = url
        view.actions = self
    }

    var name: String { (root ?? url).lastPathComponent }

    func rescan() async {
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
            log("Scanned \(url.path): \(result.scan.summary). Not recorded: no repo to record it for.")
            return
        case .repo(let found):
            location = found
        }
        self.location = location
        root = location.root
        do {
            let ledger = try openLedger(location.identity)
            let result = await scanner.scan(location, harness: harness, baseline: await ledger.workingState().baseline)
            show(result)
            let recorded = try await ledger.record(result.scan)
            log("Scanned: \(result.scan.summary). " + (recorded ? "Recorded in the ledger." : "Same as the last recorded scan."))
            await refreshLedger()
        } catch {
            log("⛔️ Couldn't record the scan: \(error)")
        }
    }

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

    func revealRepository() { NSWorkspace.shared.activateFileViewerSelecting([root ?? url]) }

    func revealStorage() {
        guard let storage else { return }
        NSWorkspace.shared.activateFileViewerSelecting([storage])
    }

    private func openLedger(_ identity: String) throws -> Ledger {
        if let ledger { return ledger }
        let ledger = try Ledger(store: RepositoryStorage.ledgerStore(for: identity))
        self.ledger = ledger
        storage = RepositoryStorage.directory(for: identity)
        return ledger
    }

    private func show(_ result: ScannedRepository) {
        view.readiness = result.scan
        view.policy = result.policy
        view.config = result.config
        view.signals = HarnessCommand.allCases.filter(result.policy.policy.allowedSignals.contains)
        view.configDraft = result.draft
    }

    private func refreshLedger() async {
        guard let ledger else { return }
        view.records = await ledger.allRecords()
        view.state = await ledger.workingState()
    }

    private func log(_ message: String) {
        view.activity.insert("\(Date.now.formatted(date: .omitted, time: .standard))  \(message)", at: 0)
    }

    // The tracker pane isn't shown for repos yet (phase 4: local tracker).
    func addLabel(_ name: String, to key: String) async {}
    func removeLabel(_ name: String, from key: String) async {}
    func comment(_ text: String, on key: String) async {}
    func createTicket(title: String, description: String, criteria: [String], blockedBy: [String]) async {}
    func edit(_ key: String, title: String, description: String, criteria: [String], blockedBy: [String]) async {}
}
