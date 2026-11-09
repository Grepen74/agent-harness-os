import AgentOSCore
import Foundation
import Observation

/// What the panes can ask for. Implemented by whatever runs the harness behind the window: the simulator
/// today, a session on a real repo later.
@MainActor
public protocol HarnessActions: AnyObject {
    func addLabel(_ name: String, to key: String) async
    func removeLabel(_ name: String, from key: String) async
    func comment(_ text: String, on key: String) async
    func createTicket(title: String, description: String, criteria: [String], blockedBy: [String]) async
    func edit(_ key: String, title: String, description: String, criteria: [String], blockedBy: [String]) async
    func verifyChain() async
    /// Demo only (shown when `offersLedgerDemo` is set).
    func tamperWithLedger() async
    func restoreLedger() async
    /// Runs the configured checks on the default branch (policy pane).
    func runBaseline() async
    /// Runs the readiness scan again (findings pane).
    func rescan() async
    func open(_ path: String)
    /// Opens the repo config in your checkout, writing the draft there first if there's none (policy pane).
    func openRepoConfig()

    // Watching agents work (all optional)
    /// The node's working copy, if it has one right now.
    func worktree(of node: NodeID) -> URL?
    /// The run's own output file (see `AgentLog`), if it has one.
    func agentLog(of node: NodeID, run: RunID) -> URL?
    /// What the node's working copy changed so far, committed or not.
    func changes(of node: NodeID) async -> String
    func reveal(_ url: URL)
    func openInXcode(_ url: URL)
}

extension HarnessActions {
    public func tamperWithLedger() async {}
    public func restoreLedger() async {}
    public func rescan() async {}
    public func runBaseline() async {}
    public func openRepoConfig() {}
    public func worktree(of node: NodeID) -> URL? { nil }
    public func agentLog(of node: NodeID, run: RunID) -> URL? { nil }
    public func changes(of node: NodeID) async -> String { "" }
    public func reveal(_ url: URL) {}
    public func openInXcode(_ url: URL) {}
}

/// Snapshots of the harness for SwiftUI. The backend copies data in after every change; the panes only
/// read it and send requests back through `actions`.
@Observable @MainActor
public final class HarnessViewModel {
    public var tickets: [Ticket] = []
    public var state = WorkingState()
    public var records: [RecordedEvent] = []
    public var chain: ChainReport?
    public var activity: [String] = []
    /// The human using the app, as shown in the tracker.
    public var you = "Alice"
    /// Signals the policy offers; the label menu shows only these.
    public var signals: [HarnessCommand] = HarnessCommand.allCases
    /// Extra labels for the label menu, e.g. the simulator's "make agents misbehave" labels.
    public var extraLabels: (title: String, names: [String])?
    /// Shows the tamper and restore buttons in the ledger pane.
    public var offersLedgerDemo = false
    /// The latest readiness scan of the repo, for the findings pane.
    public var readiness: ReadinessScan?
    public var isScanning = false
    /// What applies to the repo, the config the checks come from, and a draft if it has none (policy pane).
    public var policy: EffectivePolicy?
    public var config: RepoConfig?
    public var configDraft: String?
    public var isRunningBaseline = false
    public weak var actions: (any HarnessActions)?

    public init() {}

    public func ticket(_ key: String?) -> Ticket? { tickets.first { $0.key == key } }

    func addLabel(_ name: String, to key: String) async { await actions?.addLabel(name, to: key) }
    func removeLabel(_ name: String, from key: String) async { await actions?.removeLabel(name, from: key) }
    func comment(_ text: String, on key: String) async { await actions?.comment(text, on: key) }
    func createTicket(title: String, description: String, criteria: [String], blockedBy: [String]) async {
        await actions?.createTicket(title: title, description: description, criteria: criteria, blockedBy: blockedBy)
    }
    func edit(_ key: String, title: String, description: String, criteria: [String], blockedBy: [String]) async {
        await actions?.edit(key, title: title, description: description, criteria: criteria, blockedBy: blockedBy)
    }
    func verifyChain() async { await actions?.verifyChain() }
    func tamper() async { await actions?.tamperWithLedger() }
    func restoreLedger() async { await actions?.restoreLedger() }
    func rescan() async { await actions?.rescan() }
    func runBaseline() async { await actions?.runBaseline() }
    func open(_ path: String) { actions?.open(path) }
    func openRepoConfig() { actions?.openRepoConfig() }
    func worktree(of node: NodeID) -> URL? { actions?.worktree(of: node) }
    func agentLog(of node: NodeID, run: RunID) -> URL? { actions?.agentLog(of: node, run: run) }
    func changes(of node: NodeID) async -> String { await actions?.changes(of: node) ?? "" }
    func reveal(_ url: URL) { actions?.reveal(url) }
    func openInXcode(_ url: URL) { actions?.openInXcode(url) }
}
