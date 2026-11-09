import Foundation

/// How much agents may guess before a person must answer (phase 6). Guesses about what users observe (what to
/// check, which screen, which behaviour) always stop the node, at every level; this sets what happens to the
/// rest, the assumptions. Ordered from strictest to loosest: a repo may only choose a stricter level.
public enum Guesswork: String, Codable, Sendable, CaseIterable, Comparable {
    /// Any open question or assumption stops the node.
    case ask
    /// Assumptions are posted on the ticket; a leaf whose work rests on assumptions waits for a person to approve
    /// its build after seeing its acceptance tests, even under `harness:go`.
    case assumeAndReport = "assume-and-report"
    /// Assumptions are posted on the ticket; nothing waits for them.
    case autonomous

    public var title: String {
        switch self {
        case .ask: "ask"
        case .assumeAndReport: "assume and report"
        case .autonomous: "autonomous"
        }
    }

    public static func < (lhs: Guesswork, rhs: Guesswork) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Central rules (doc 01: repos declare, central policy decides). One profile in the mock.
/// Production: policy as code in its own reviewed repo, several profiles, stricter-only overrides.
public struct Policy: Sendable, Equatable {
    /// Attempts per leaf before a human must look (the Ralph-loop guardrail, doc 02 §7).
    public var maxAttempts = 3
    /// Merge-conflict reworks per leaf before a human (or a smarter planner) should order the work (doc 08 §5).
    public var maxReworks = 3
    /// Nodes worked on at the same time in a round: the agents the harness starts, not the sub-agents they use.
    /// Landing is always one at a time.
    public var maxParallelAgents = 1
    /// The signals people may use (doc 05 §3). Production: the harness layer sets what each profile may offer
    /// and the repo config may only switch signals off (doc 04 §8); strict profiles leave out `go`.
    public var allowedSignals: Set<HarnessCommand>
    /// Files no leaf may change, e.g. the agents' own instructions (doc 04 §8). Like .gitignore: a pattern
    /// without "/" matches a file name in any folder, a trailing "/" means a folder, `*` is a wildcard.
    public var protectedPaths: [String]
    public var guesswork: Guesswork

    public init(maxAttempts: Int = 3, maxReworks: Int = 3, maxParallelAgents: Int = 1,
                allowedSignals: Set<HarnessCommand> = Set(HarnessCommand.allCases), protectedPaths: [String] = [],
                guesswork: Guesswork = .assumeAndReport) {
        self.maxAttempts = maxAttempts
        self.maxReworks = maxReworks
        self.maxParallelAgents = maxParallelAgents
        self.allowedSignals = allowedSignals
        self.protectedPaths = protectedPaths
        self.guesswork = guesswork
    }

    /// What stops a node: the agent's questions, plus its assumptions when it may not assume anything.
    func questions(in report: AgentReport) -> [String] {
        guesswork == .ask ? report.questions + report.assumptions : report.questions
    }

    /// The changed files that touch a protected path.
    public func protectedPathViolations(_ files: [String]) -> [String] {
        files.filter { file in protectedPaths.contains { Self.matches(file, $0) } }
    }

    static func matches(_ file: String, _ pattern: String) -> Bool {
        let components = file.split(separator: "/").map(String.init)
        if pattern.hasSuffix("/") {
            let folder = String(pattern.dropLast())
            if folder.contains("/") { return file.hasPrefix(pattern) }
            return components.dropLast().contains { fnmatch(folder, $0, 0) == 0 }
        }
        if pattern.contains("/") { return fnmatch(pattern, file, FNM_PATHNAME) == 0 }
        return components.last.map { fnmatch(pattern, $0, 0) == 0 } ?? false
    }

    func escalationReason(for node: NodeState) -> String? {
        let failures = node.recentFailures
        if failures.count >= 2, failures[failures.count - 1] == failures[failures.count - 2] {
            return "No progress: the same failure twice in a row (\(failures.last!))"
        }
        if node.reworks > maxReworks {
            return "Reworked \(node.reworks) times after merge conflicts: other work keeps landing in the same place"
        }
        if node.failedAttempts >= maxAttempts {
            return "Failed \(node.failedAttempts) times (limit \(maxAttempts)). Last: \(failures.last ?? "unknown")"
        }
        return nil
    }

    /// Definition of Ready (doc 05 §5): what a ticket needs before agents may start on it.
    func readinessProblems(_ ticket: Ticket) -> [String] {
        var problems: [String] = []
        if ticket.title.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("a title") }
        if ticket.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("a description (the why)") }
        if ticket.acceptanceCriteria.isEmpty { problems.append("at least one acceptance criterion") }
        return problems
    }

    /// Ticket status shown to humans: a projection of the ledger, never the source (doc 03 §5).
    func trackerStatus(for node: NodeState) -> String {
        if node.flags[.escalated] != nil { return "Needs human" }
        if node.flags[.needsInput] != nil { return "Needs input" }
        if node.flags[.blocked] != nil { return "Blocked" }
        switch node.phase {
        case .specified: return node.spec.kind == .composite ? "Breaking down" : "Specifying"
        case .split: return "In progress"
        case .ready: return "Ready"
        case .building: return "In progress"
        case .checking: return "In review"
        case .landing: return "Landing"
        case .proven: return "Done"
        }
    }
}

/// Turns proposals into Work Nodes.
enum Planner {
    static func rootSpec(for ticket: Ticket) -> NodeSpec {
        NodeSpec(
            id: "wn-\(ticket.key)", parent: nil, kind: .composite, title: ticket.title, intent: ticket.description,
            acceptanceCriteria: ticket.acceptanceCriteria, dependsOn: ticket.blockedBy)
    }

    static func childSpecs(parent: NodeSpec, proposals: [ChildProposal]) -> [NodeSpec] {
        // Production: the leaf check (doc 02 §4, doc 08 §1) decides per child whether it needs further
        // breakdown, e.g. because its touch set spans repos or profiles. The mock has one repo and one
        // profile, so every child is a leaf and the tree is two levels deep.
        proposals.enumerated().map { index, proposal in
            let touches = (proposal.touches ?? []).map { ComponentName.from($0) }
            return NodeSpec(
                id: "\(parent.id).\(index + 1)", parent: parent.id, kind: .leaf, title: proposal.title,
                intent: "Part of \(parent.title)", acceptanceCriteria: proposal.acceptanceCriteria,
                touches: touches.isEmpty ? [ComponentName.from(parent.title, maxWords: 3)] : Array(Set(touches)).sorted(),
                dependsOn: proposal.dependsOn ?? [])
        }
    }

    static func describe(_ specs: [NodeSpec], under title: String) -> String {
        guard specs.count > 1 else {
            let touches = specs.first.map { " (touches: \($0.touches.joined(separator: ", ")))" } ?? ""
            return "\(title)\n└─ no children: it is a leaf itself\(touches)"
        }
        let lines = specs.enumerated().map { index, spec in
            let branch = index == specs.count - 1 ? "└─" : "├─"
            let waits = spec.dependsOn.isEmpty ? "" : "  (waits for \(spec.dependsOn.joined(separator: ", ")))"
            return "\(branch) \(spec.title)  touches: \(spec.touches.joined(separator: ", "))\(waits)"
        }
        return ([title] + lines).joined(separator: "\n")
    }
}
