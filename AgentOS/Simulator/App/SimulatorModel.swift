import AgentOSCore
import AppKit
import Foundation
import Observation

/// UI state. The simulation's actors are the source of truth; this copies snapshots for SwiftUI.
@Observable @MainActor
final class SimulatorModel {
    enum AgentMode: String, CaseIterable, Identifiable {
        case scripted = "Scripted agents"
        case copilot = "Copilot CLI agents"
        var id: String { rawValue }
    }

    let directory: URL
    private(set) var simulation: Simulation
    var tickets: [Ticket] = []
    var state = WorkingState()
    var records: [RecordedEvent] = []
    var externalItems: [ExternalItem] = []
    var chain: ChainReport?
    var activity: [String] = []
    var isRunning = false
    var isBusy = false
    /// Shown only for rounds that take noticeable time, so fast idle rounds don't make the toolbar flicker.
    var showsActivity = false
    var agentMode = AgentMode.scripted { didSet { Task { await applyAgentMode() } } }
    var you = "Alice"
    private var runTask: Task<Void, Never>?

    init() {
        directory = URL.applicationSupportDirectory.appending(path: "AgentOSSimulator")
        simulation = Self.open(directory)
        Task { await refresh() }
    }

    private static func open(_ directory: URL) -> Simulation {
        do { return try Simulation(directory: directory) }
        catch { fatalError("Couldn't open simulation at \(directory.path): \(error)") }
    }

    var human: Participant { .human(you.isEmpty ? "Someone" : you) }

    func ticket(_ key: String?) -> Ticket? { tickets.first { $0.key == key } }

    // MARK: Harness

    /// One reconciler round, like the harness waking up once.
    func step() async {
        guard !isBusy else { return }
        isBusy = true
        let indicator = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { showsActivity = true }
        }
        let report = await simulation.step()
        indicator.cancel()
        showsActivity = false
        isBusy = false
        log(report)
        await refresh()
    }

    /// Run = the always-on service: a round about every second (production: woken by events too).
    func setRunning(_ running: Bool) {
        isRunning = running
        runTask?.cancel()
        guard running else { return }
        runTask = Task {
            while !Task.isCancelled {
                await step()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func applyAgentMode() async {
        switch agentMode {
        case .scripted:
            await simulation.reconciler.setTeam(.scripted)
        case .copilot:
            guard let path = CopilotCLI.locate() else {
                activity.insert("Copilot CLI not found; staying on scripted agents.", at: 0)
                agentMode = .scripted
                return
            }
            await simulation.reconciler.setTeam(.copilot(CopilotCLI(executable: path)))
        }
        activity.insert("Agents: \(agentMode.rawValue)", at: 0)
    }

    private func log(_ report: RoundReport) {
        if let stop = report.safeStop {
            activity.insert("⛔️ \(stop)", at: 0)
            setRunning(false)
        }
        let time = Date.now.formatted(date: .omitted, time: .standard)
        activity.insert(contentsOf: report.actions.map { "\(time)  \($0)" }, at: 0)
        activity = Array(activity.prefix(300))
    }

    // MARK: Human actions in the tracker / other system

    func addLabel(_ name: String, to key: String) async { await simulation.tracker.addLabel(name, to: key, by: human); await refresh() }
    func removeLabel(_ name: String, from key: String) async { await simulation.tracker.removeLabel(name, from: key); await refresh() }
    func comment(_ text: String, on key: String) async { await simulation.tracker.addComment(text, to: key, by: human); await refresh() }

    func createTicket(title: String, description: String, criteria: [String], blockedBy: [String]) async {
        await simulation.tracker.createTicket(title: title, description: description, acceptanceCriteria: criteria,
                                              blockedBy: blockedBy, by: human)
        await refresh()
    }

    func edit(_ key: String, title: String, description: String, criteria: [String], blockedBy: [String]) async {
        await simulation.tracker.edit(key, title: title, description: description, acceptanceCriteria: criteria, blockedBy: blockedBy)
        await refresh()
    }

    func addExternal(key: String, title: String, owner: String) async { await simulation.external.add(key: key, title: title, owner: owner); await refresh() }
    func deliver(_ key: String) async { await simulation.external.deliver(key); await refresh() }

    // MARK: Ledger

    func verifyChain() async { chain = await simulation.ledger.verifyChain() }

    func tamper() async {
        try? await simulation.ledger.tamperForDemo()
        await verifyChain()
        activity.insert("🕵️ Someone edited a ledger record directly on disk.", at: 0)
    }

    // MARK: Lifecycle

    func loadDemo() async { await simulation.loadDemo(by: you); await refresh() }
    func loadConflictingTicket() async { await simulation.loadConflictingTicket(by: you); await refresh() }

    func reset() async {
        setRunning(false)
        try? Simulation.reset(directory: directory)
        simulation = Self.open(directory)
        activity = ["Reset."]
        chain = nil
        await applyAgentMode()
        await refresh()
    }

    /// Like restarting the harness process: reload everything from disk and reclaim unfinished runs.
    func restartHarness() async {
        setRunning(false)
        simulation = Self.open(directory)
        await applyAgentMode()
        let notes = await simulation.reconciler.recoverAfterRestart()
        activity.insert(contentsOf: ["🔄 Harness restarted from the ledger."] + notes, at: 0)
        await refresh()
    }

    func openWorkspace() { NSWorkspace.shared.open(simulation.workspace.root) }
    func open(_ path: String) { NSWorkspace.shared.open(URL(filePath: path)) }

    func refresh() async {
        tickets = await simulation.tracker.tickets()
        state = await simulation.ledger.workingState()
        records = await simulation.ledger.allRecords()
        externalItems = await simulation.external.items()
    }
}
