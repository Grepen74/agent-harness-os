import Foundation

/// Wires the pieces together: one tracker, one ledger, one external system, one workspace and one
/// reconciler, all stored under a single directory so the whole simulation survives restarts.
///
///     <directory>/ledger.jsonl    the ledger (one JSON record per line, hash-chained)
///     <directory>/tracker.json    the mock tracker (what humans see)
///     <directory>/external.json   the mock "other team's" system
///     <directory>/workspace/      the product's git monorepo, one working copy per leaf, check logs
public final class Simulation: Sendable {
    public let directory: URL
    public let ledger: Ledger
    public let tracker: MockTracker
    public let external: MockExternalSystem
    public let workspace: Workspace
    public let reconciler: Reconciler

    public init(directory: URL, team: AgentTeam = .scripted, checks: any CheckRunner = SwiftPMCheckRunner(),
                policy: Policy = Policy()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        ledger = try Ledger(fileURL: directory.appending(path: "ledger.jsonl"))
        tracker = MockTracker(fileURL: directory.appending(path: "tracker.json"))
        external = MockExternalSystem(fileURL: directory.appending(path: "external.json"))
        workspace = Workspace(root: directory.appending(path: "workspace"))
        reconciler = Reconciler(
            ledger: ledger, tracker: MockTrackerAdapter(tracker: tracker), external: external,
            workspace: workspace, checks: checks, team: team, policy: policy)
    }

    /// One reconciler round.
    @discardableResult
    public func step() async -> RoundReport { await reconciler.runRound() }

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

    /// Demo content (doc 08): an epic whose leaves overlap in the components they touch and depend on
    /// another team's API, a ticket that isn't ready yet, and a later ticket that contradicts the first.
    /// The `[A, B]` suffix tells the scripted decomposer which components a criterion touches.
    public func loadDemo(by person: String = "Alice") async {
        await external.add(key: "BACKEND-42", title: "Weather API v2 endpoint", owner: "Backend team")
        await tracker.createTicket(
            title: "Weather widget",
            description: "Users want to see today's weather at a glance on the home screen.",
            acceptanceCriteria: [
                "Temperature unit: Celsius [WeatherService, WeatherUI]",
                "Shows an icon matching the weather condition [WeatherUI]",
                "Fetches the forecast from BACKEND-42 [WeatherAPIClient, WeatherService]",
            ],
            blockedBy: ["BACKEND-42"], by: .human(person))
        await tracker.createTicket(
            title: "Dark mode", description: "Someone mentioned dark mode in a meeting.",
            acceptanceCriteria: [], by: .human(person))
    }

    /// A second team's ticket that silently contradicts "Temperature unit: Celsius" (doc 08 §5).
    @discardableResult
    public func loadConflictingTicket(by person: String = "Bob") async -> String {
        await tracker.createTicket(
            title: "Trip mode for US travel",
            description: "Travellers to the US want the widget to feel local.",
            acceptanceCriteria: [
                "Temperature unit: Fahrenheit [WeatherService]",
                "Shows the destination city name [WeatherUI]",
            ],
            by: .human(person)).key
    }

    /// Text tree of the work, for the CLI and for quick inspection (doc 06).
    public func treeDescription() async -> String {
        let state = await ledger.workingState()
        var lines: [String] = []
        func walk(_ node: NodeState, depth: Int) {
            var flags = node.flags.keys.map(\.rawValue).sorted().map { " ⚑\($0)" }.joined()
            if let run = node.activeRun { flags += " ⏳\(run.role.rawValue)" }
            if node.reworks > 0 { flags += " ♻️\(node.reworks)" }
            let icon = node.phase == .proven ? "✅" : "•"
            lines.append(String(repeating: "   ", count: depth) +
                "\(icon) \(node.ticket) \(node.spec.title) [\(node.phase.rawValue)]\(flags)")
            for child in node.children.compactMap({ state.nodes[$0] }) { walk(child, depth: depth + 1) }
        }
        for root in state.roots { walk(root, depth: 0) }
        return lines.isEmpty ? "(no work nodes yet)" : lines.joined(separator: "\n")
    }

    /// Deletes everything in the simulation directory. Create a new `Simulation` afterwards.
    public static func reset(directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
