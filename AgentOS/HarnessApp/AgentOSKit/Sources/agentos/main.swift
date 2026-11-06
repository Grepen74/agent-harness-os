import AgentOSAdapters
import AgentOSCore
import AgentOSSimulation
import Foundation

// `agentos demo` plays the human's part with scripted actions, so the whole flow runs without a UI:
// preview → breakdown → build in parallel → landing queue (merge conflicts → rework) → a contradicting
// ticket (requirements conflict → escalated) → other team delivers → proven. Then it checks the ledger.

let usage = """
    usage: agentos demo [--dir <path>] [--agents scripted|copilot] [--keep]
           agentos tree [--dir <path>]
           agentos verify [--dir <path>]
           agentos scan [<repo path>]      readiness scan of a real repo (read-only)
           agentos baseline [<repo path>] [--config <file>]
                                           run the repo's checks on its default branch, outside your checkout
           agentos work [<repo path>] [--ticket <title> [--description <text>] [--criterion <text>]... [--go]]
                                           run Copilot agents on the repo's local tracker until nothing is left
                                           to do without a human; proven work lands on agentos/main
    """

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
func options(_ name: String) -> [String] {
    arguments.indices.filter { arguments[$0] == name && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
}
/// The first argument after the command that is neither an option nor an option's value.
func positional() -> String? {
    let withValues: Set<String> = ["--dir", "--agents", "--config", "--ticket", "--description", "--criterion"]
    var index = 1
    while index < arguments.count {
        if withValues.contains(arguments[index]) { index += 2; continue }
        if !arguments[index].hasPrefix("--") { return arguments[index] }
        index += 1
    }
    return nil
}
let command = arguments.first ?? "demo"
let directory = URL(filePath: option("--dir") ?? FileManager.default.temporaryDirectory.appending(path: "agentos-demo").path)

/// An absolute folder URL: git runs with it as its working directory, where a relative path doesn't resolve.
func repoURL(_ path: String) -> URL {
    URL(filePath: path, directoryHint: .isDirectory, relativeTo: .currentDirectory()).absoluteURL.standardized
}

func makeTeam() -> AgentTeam {
    guard option("--agents") == "copilot" else { return .scripted }
    guard let path = CopilotCLI.locate() else {
        print("Copilot CLI not found; using scripted agents.")
        return .scripted
    }
    return .copilot(CopilotCLI(executable: path))
}

func say(_ text: String) { print("\n\u{001B}[1m\(text)\u{001B}[0m") }

func run(_ sim: Simulation) async {
    await sim.runUntilIdle { report in
        for action in report.actions { print("  · \(action)") }
        if let stop = report.safeStop { print("  ⛔️ \(stop)") }
    }
}

func comments(_ sim: Simulation, _ key: String, last count: Int = 1) async {
    for comment in (await sim.tracker.ticket(key)?.comments ?? []).suffix(count) {
        print("  💬 [\(comment.author.label)] " + comment.text.replacingOccurrences(of: "\n", with: "\n     "))
    }
}

switch command {
case "demo":
    if !arguments.contains("--keep") { try Simulation.reset(directory: directory) }
    let sim = try Simulation(directory: directory, team: makeTeam())
    let alice = Participant.human("Alice")
    say("Workspace: \(directory.path)")
    await sim.loadDemo()

    say("1. Nothing happens without a deliberate signal")
    await run(sim)
    print(await sim.treeDescription())

    say("2. An agent tries to start work itself (rejected), Alice asks for a preview of the 'Dark mode' idea")
    await sim.tracker.addLabel("harness:breakdown", to: "APP-1", by: .agent(run: "rogue", role: .implementer))
    await sim.tracker.addLabel("harness:preview", to: "APP-2", by: alice)
    await run(sim)
    await comments(sim, "APP-1"); await comments(sim, "APP-2")

    say("3. Alice previews the weather widget epic")
    await sim.tracker.addLabel("harness:preview", to: "APP-1", by: alice)
    await run(sim)
    await comments(sim, "APP-1", last: 2)

    say("4. Alice approves the breakdown")
    await sim.tracker.addLabel("harness:breakdown", to: "APP-1", by: alice)
    await run(sim)
    print(await sim.treeDescription())

    say("5. Alice approves building. Leaves build in parallel on their own branches, then queue to land")
    await sim.tracker.addLabel("harness:build", to: "APP-1", by: alice)
    await run(sim)
    print(await sim.treeDescription())

    say("6. Bob files a ticket that quietly contradicts APP-1, and approves it straight away")
    let trip = await sim.loadConflictingTicket()
    let bob = Participant.human("Bob")
    await sim.tracker.addLabel("harness:breakdown", to: trip, by: bob)
    await run(sim)
    await sim.tracker.addLabel("harness:build", to: trip, by: bob)
    await run(sim)
    print(await sim.treeDescription())

    say("7. The backend team delivers BACKEND-42")
    await sim.external.deliver("BACKEND-42")
    await run(sim)
    print(await sim.treeDescription())

    say("8. Needs a human")
    var state = await sim.ledger.workingState()
    for item in state.attentionList { print("  ⚑ \(item.node.ticket) \(item.node.spec.title): \(item.reason)") }

    say("9. main, as landed by the queue (author = the run that built it)")
    for line in (try? await sim.workspace.mainLog()) ?? [] { print("  \(line)") }

    say("10. Ledger integrity")
    let report = await sim.ledger.verifyChain()
    print("  \(report.checked) records, chain \(report.isIntact ? "intact ✅" : "BROKEN ❌ \(report.problem!.reason)")")
    state = await sim.ledger.workingState()
    let widgetProven = state.node(forTicket: "APP-1")?.phase == .proven
    let reworked = state.nodes.values.contains { $0.reworks > 0 }
    let conflictEscalated = state.attentionList.contains { $0.reason.hasPrefix("Requirements conflict") }
    print("  APP-1 proven: \(widgetProven ? "yes ✅" : "no ❌")")
    print("  Merge conflicts resolved by rework: \(reworked ? "yes ✅" : "no ❌")")
    print("  Requirements conflict escalated: \(conflictEscalated ? "yes ✅" : "no ❌")")
    exit(widgetProven && reworked && conflictEscalated && report.isIntact ? 0 : 1)

case "tree":
    print(await (try Simulation(directory: directory)).treeDescription())

case "scan":
    let path = arguments.dropFirst().first { !$0.hasPrefix("--") } ?? FileManager.default.currentDirectoryPath
    let url = repoURL(path)
    let scanner = ReadinessScanner()
    let result: ScannedRepository
    switch await scanner.locate(url) {
    case .blocked(let blocked): result = blocked
    case .repo(let location):
        let ledger = try Ledger(store: RepositoryStorage.ledgerStore(for: location.identity))
        result = await scanner.scan(location, baseline: await ledger.workingState().baseline)
    }
    let icons: [Finding.Severity: String] = [.blocker: "⛔️", .warning: "⚠️ ", .info: "ℹ️ "]
    say("Readiness scan of \(result.root?.path ?? path)")
    for finding in result.scan.findings {
        print("\(icons[finding.severity]!) \(finding.title)")
        if !finding.detail.isEmpty { print("     \(finding.detail)") }
        if let suggestion = finding.suggestion { print("     → \(suggestion)") }
    }
    if let draft = result.draft {
        say("Draft \(RepoConfig.path) (check it, then commit it)")
        print(draft)
    }
    print("\n\(result.scan.summary). \(result.scan.isReady ? "Ready for agents." : "Not ready: fix the blockers first.")")
    exit(result.scan.isReady ? 0 : 1)

case "baseline":
    // The repo's committed config, or `--config <file>` to try one before committing it (not recorded then).
    let path = arguments.dropFirst().first { !$0.hasPrefix("--") && $0 != option("--config") }
        ?? FileManager.default.currentDirectoryPath
    let scanner = ReadinessScanner()
    guard case .repo(let location) = await scanner.locate(repoURL(path)) else {
        print("Not a git repo with a default branch: \(path)")
        exit(1)
    }
    let config: RepoConfig
    let trial = option("--config")
    if let trial {
        do {
            config = try RepoConfig.parse(try String(contentsOfFile: trial, encoding: .utf8)).config
        } catch {
            print("\(trial): \(error)")
            exit(1)
        }
    } else {
        guard let committed = await scanner.scan(location).config else {
            print("No valid \(RepoConfig.path) on \(location.branch). Try one with --config <file>.")
            exit(1)
        }
        config = committed
    }
    let storage = RepositoryStorage.directory(for: location.identity)
    say("Baseline of \(location.branch) at \(location.commit.prefix(8))")
    for step in CommandCheckRunner(config: config).steps() { print("  $ \(step.command)") }
    let baseline = await BaselineRunner(storage: storage).run(config: config, commit: location.commit, repo: location.root)
    print("\n\(baseline.passed ? "✅ Passed" : "❌ Failed") in \(baseline.seconds)s: \(baseline.summary)")
    if let log = baseline.log { print("Log: \(log.path)") }
    if trial == nil {
        try await Ledger(store: RepositoryStorage.ledgerStore(for: location.identity)).record(baseline)
        print("Recorded in the repo's ledger.")
    } else {
        print("Trial config: not recorded.")
    }
    exit(baseline.passed ? 0 : 1)

case "work":
    // Uses the default harness settings (the app's Settings window doesn't apply here).
    let path = positional() ?? FileManager.default.currentDirectoryPath
    let scanner = ReadinessScanner()
    guard case .repo(let location) = await scanner.locate(repoURL(path)) else {
        print("Not a git repo with a default branch: \(path)")
        exit(1)
    }
    let ledger = try Ledger(store: RepositoryStorage.ledgerStore(for: location.identity))
    let scanned = await scanner.scan(location, baseline: await ledger.workingState().baseline)
    try await ledger.record(scanned.scan)
    let blockers = RepositorySession.blockers(scanned.scan)
    guard blockers.isEmpty, let config = scanned.config else {
        print("Not ready for agents (run `agentos scan` for details):")
        for blocker in blockers { print("  ⛔️ \(blocker)") }
        exit(1)
    }
    guard let copilot = CopilotCLI.locate() else {
        print("Copilot CLI not found.")
        exit(1)
    }
    let session = try RepositorySession(
        location: location, storage: RepositoryStorage.directory(for: location.identity), ledger: ledger, config: config,
        policy: scanned.policy, team: RepositorySession.copilotTeam(executable: copilot, policy: scanned.policy))
    for note in await session.reconciler.recoverAfterRestart() { print("  · \(note)") }
    let you = Participant.human(NSUserName())
    if let title = option("--ticket") {
        let ticket = await session.tracker.createTicket(
            title: title, description: option("--description") ?? title, acceptanceCriteria: options("--criterion"), by: you)
        print("Created \(ticket.key): \(title)")
        if arguments.contains("--go") { await session.tracker.addLabel(HarnessCommand.go.label, to: ticket.key, by: you) }
    }
    say("Working on \(location.root.lastPathComponent); landing on \(scanned.policy.landingBranch)")
    await session.runUntilIdle { report in
        for action in report.actions { print("  · \(action)") }
        if let stop = report.safeStop { print("  ⛔️ \(stop)") }
    }
    let state = await ledger.workingState()
    for ticket in await session.tracker.tickets() {
        let phase = state.node(forTicket: ticket.key).map { " [\($0.phase.rawValue)]" } ?? ""
        print("  \(ticket.key) \(ticket.status)\(phase): \(ticket.title)")
        if let last = ticket.comments.last { print("     💬 " + last.text.replacingOccurrences(of: "\n", with: "\n        ")) }
    }

case "verify":
    let report = await (try Simulation(directory: directory)).ledger.verifyChain()
    print(report.isIntact ? "Intact: \(report.checked) records" : "Broken at #\(report.problem!.position): \(report.problem!.reason)")
    exit(report.isIntact ? 0 : 1)

default:
    print(usage)
    exit(2)
}
