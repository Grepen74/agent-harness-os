import AgentOSAdapters
import AgentOSCore
import AgentOSUI
import AppKit
import Observation

/// The harness on one real repo. Phase 2: the read-only readiness scan, recorded in the repo's own ledger
/// (outside the repo, see `RepositoryStorage`). Tickets and agents come in later phases.
@Observable @MainActor
final class RepositoryModel: HarnessActions {
    let url: URL
    let view = HarnessViewModel()
    private(set) var root: URL?
    private(set) var storage: URL?
    @ObservationIgnored private var ledger: Ledger?
    @ObservationIgnored private let scanner = ReadinessScanner()

    init(url: URL) {
        self.url = url
        view.actions = self
    }

    var name: String { (root ?? url).lastPathComponent }

    func rescan() async {
        guard !view.isScanning else { return }
        view.isScanning = true
        defer { view.isScanning = false }

        let result = await scanner.scan(url)
        root = result.root
        view.readiness = result.scan
        let time = Date.now.formatted(date: .omitted, time: .standard)
        guard let identity = result.identity else {
            view.activity.insert("\(time)  Scanned \(url.path): \(result.scan.summary). Not recorded: no repo to record it for.", at: 0)
            return
        }
        do {
            let ledger = try self.ledger ?? Ledger(store: RepositoryStorage.ledgerStore(for: identity))
            self.ledger = ledger
            storage = RepositoryStorage.directory(for: identity)
            let recorded = try await ledger.record(result.scan)
            view.activity.insert("\(time)  Scanned: \(result.scan.summary). "
                + (recorded ? "Recorded in the ledger." : "Same as the last recorded scan."), at: 0)
            view.records = await ledger.allRecords()
            view.state = await ledger.workingState()
        } catch {
            view.activity.insert("\(time)  ⛔️ Couldn't record the scan: \(error)", at: 0)
        }
    }

    func verifyChain() async { view.chain = await ledger?.verifyChain() }

    func open(_ path: String) { NSWorkspace.shared.open(URL(filePath: path)) }

    func revealRepository() { NSWorkspace.shared.activateFileViewerSelecting([root ?? url]) }

    func revealStorage() {
        guard let storage else { return }
        NSWorkspace.shared.activateFileViewerSelecting([storage])
    }

    // The tracker pane isn't shown for repos yet (phase 4: local tracker).
    func addLabel(_ name: String, to key: String) async {}
    func removeLabel(_ name: String, from key: String) async {}
    func comment(_ text: String, on key: String) async {}
    func createTicket(title: String, description: String, criteria: [String], blockedBy: [String]) async {}
    func edit(_ key: String, title: String, description: String, criteria: [String], blockedBy: [String]) async {}
}
