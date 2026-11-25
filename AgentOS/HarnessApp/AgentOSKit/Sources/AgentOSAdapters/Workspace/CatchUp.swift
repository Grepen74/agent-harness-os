import AgentOSCore
import Foundation

public struct CatchUpBanner: Sendable {
    public enum Level: Sendable {
        case warning
    }

    public let level: Level
    public let message: String
}

public struct CatchUpAttentionItem: Sendable {
    public enum Scope: Sendable {
        case repository
    }

    public enum Level: Sendable {
        case needsHuman
    }

    public enum Action: Sendable, Hashable {
        case showDiff
        case retryCatchUp
        case openInTerminal
    }

    public let scope: Scope
    public let title: String
    public let level: Level
    public let message: String
    public let actions: [Action]
}

public struct CatchUpStatus: Sendable {
    public let conflict: CatchUpConflict?
    public let lastSuccess: CatchUpSuccess?
    public let banner: CatchUpBanner?
    public let attentionItems: [CatchUpAttentionItem]
    public let scanFinding: Finding?
}

public actor LandingQueue {
    private let permit = AsyncSemaphore(1)

    public init() {}

    @discardableResult
    public nonisolated func runLanding<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await permit.withPermit(operation)
    }
}

public struct CatchUpOutcome: Sendable {
    public let targetMain: String
    public let oldLandingTip: String
    public let newLandingTip: String
    public let method: CatchUpReconciliationMethod
    public let commitMappings: [String: String]
    public let status: CatchUpOutcomeStatus
}

public struct CatchUpOutcomeStatus: Sendable {
    public let banner: String
    public let scanFinding: Finding
}

public actor CatchUpCoordinator {
    let workspace: RepositoryWorkspace
    let ledger: Ledger
    let tracker: (any TicketBoard)?
    let landingQueue: LandingQueue
    let requirement: NodeIdentity?
    private var landingBranch: String { requirement.map { "agentos/\($0.ticketKey)" } ?? workspace.defaultBranch }

    init(workspace: RepositoryWorkspace, ledger: Ledger, tracker: any TicketBoard) {
        self.workspace = workspace
        self.ledger = ledger
        self.tracker = tracker
        landingQueue = LandingQueue()
        requirement = nil
    }

    public init(workspace: RepositoryWorkspace, ledger: Ledger, landingQueue: LandingQueue) {
        self.workspace = workspace
        self.ledger = ledger
        tracker = nil
        self.landingQueue = landingQueue
        requirement = nil
    }

    init(workspace: RepositoryWorkspace, ledger: Ledger, tracker: (any TicketBoard)?,
                 landingQueue: LandingQueue, requirement: NodeIdentity) {
        self.workspace = workspace
        self.ledger = ledger
        self.tracker = tracker
        self.landingQueue = landingQueue
        self.requirement = requirement
    }

    func catchUpRequirement(
        after baseline: Baseline,
        acceptanceTests: @escaping @Sendable (URL) async throws -> Bool
    ) async throws -> CatchUpOutcome? {
        return try await landingQueue.runLanding { [self] in
            try await performCatchUp(to: baseline.commit, acceptanceTests: acceptanceTests)
        }
    }

    /// `busy`: nodes with a step in progress. Their worktrees are left alone; landing rebases them later.
    func reconcileRequirement(force: Bool, busy: Set<NodeID>) async -> String? {
        do {
            try await workspace.prepare()
            try await workspace.removeCatchUpMergeAids()
            let main = try await workspace.localMainTip()
            let landing = try await revision(landingBranch)
            let state = await ledger.workingState()
            let currentConflict = requirement.flatMap { state.nodes[$0.nodeID]?.catchUpConflict }

            if let conflict = currentConflict,
               try await isAncestor(conflict.mainSHA, of: landing) {
                try await recordSuccess(main: conflict.mainSHA, tip: landing, method: .manual, busy: busy)
                return "Manual catch-up to \(conflict.mainSHA.prefix(8)) recognized"
            }

            if try await isAncestor(main, of: landing) {
                await projectConflict(currentConflict)
                return nil
            }
            if !force, currentConflict?.mainSHA == main {
                await projectConflict(currentConflict)
                return nil
            }

            let result = try await workspace.mergeRequirementBranch(landingBranch, main: main)
            switch result {
            case .success(let tip):
                try await recordSuccess(main: main, tip: tip, method: .automatic, busy: busy)
                return "Caught \(landingBranch) up to \(main.prefix(8))"
            case .conflict(let files):
                let ticketFiles = try await affectedTickets(for: files, state: state)
                let tickets = ticketFiles.keys.sorted()
                try await ledger.append([
                    LedgerEvent(
                        node: requirement?.nodeID,
                        by: .adapter("Catch-up"),
                        kind: .catchUpConflicted(main: main, files: files.sorted(), tickets: tickets)
                    ),
                ])
                let conflict = CatchUpConflict(mainSHA: main, files: files.sorted(), tickets: tickets)
                await notify(ticketFiles, main: main)
                await projectConflict(conflict)
                return "Catch-up to \(main.prefix(8)) conflicted"
            }
        } catch {
            return "⚠️ Catch-up failed: \(error)"
        }
    }

    func requirementStatus(in state: WorkingState) async -> CatchUpStatus {
        let node = requirement.flatMap { state.nodes[$0.nodeID] }
        guard let conflict = node?.catchUpConflict else {
            return CatchUpStatus(
                conflict: nil,
                lastSuccess: node?.lastCatchUpSuccess,
                banner: nil,
                attentionItems: [],
                scanFinding: nil
            )
        }
        let message = await conflictMessage(conflict, state: state)
        let behind = (try? await git(["rev-list", "--count", "\(landingBranch)..\(workspace.defaultBranch)"],
                                     in: workspace.root)) ?? "0"
        let banner = CatchUpBanner(level: .warning, message: message)
        let item = CatchUpAttentionItem(
            scope: .repository,
            title: "Catch-up conflict",
            level: .needsHuman,
            message: message,
            actions: [.showDiff, .retryCatchUp, .openInTerminal]
        )
        let finding = Finding(
            check: "repository.catch-up",
            severity: .warning,
            title: "\(landingBranch) is \(behind) commit\(behind == "1" ? "" : "s") behind main: catch-up conflict in \(conflict.files.count) files"
        )
        return CatchUpStatus(
            conflict: conflict,
            lastSuccess: node?.lastCatchUpSuccess,
            banner: banner,
            attentionItems: [item],
            scanFinding: finding
        )
    }

    func requirementConflictDiff() async throws -> String {
        guard let requirement, let conflict = await ledger.workingState().nodes[requirement.nodeID]?.catchUpConflict else {
            throw AgentFailure("There is no catch-up conflict.")
        }
        let directory = workspace.worktreesDirectory.appending(path: "catch-up-diff-\(UUID().uuidString)")
        try await workspace.removeCatchUpMergeAids()
        try await addDetachedWorktree(directory)
        _ = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "merge", "--no-commit", "--no-ff", conflict.mainSHA], in: directory)
        let diff = try await git(["diff", "--no-ext-diff"], in: directory)
        try await removeWorktree(directory)
        return diff
    }

    func openRequirementInTerminal() async throws -> URL {
        guard let requirement, let conflict = await ledger.workingState().nodes[requirement.nodeID]?.catchUpConflict else {
            throw AgentFailure("There is no catch-up conflict.")
        }
        let directory = workspace.worktreesDirectory.appending(path: "catch-up-\(conflict.mainSHA.prefix(12))")
        if FileManager.default.fileExists(atPath: directory.path) {
            try await removeWorktree(directory)
        }
        try await workspace.removeCatchUpMergeAids()
        try await addDetachedWorktree(directory)
        let result = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "merge", "--no-commit", "--no-ff", conflict.mainSHA], in: directory)
        guard result.status != 0 else {
            throw AgentFailure("The recorded catch-up no longer conflicts.")
        }
        return directory
    }

    private func affectedTickets(
        for conflictFiles: [String],
        state: WorkingState
    ) async throws -> [String: [String]] {
        var result: [String: Set<String>] = [:]
        let conflicts = Set(conflictFiles)
        for node in state.nodes.values where node.phase == .proven {
            guard state.lineage(of: node.id).last?.id == requirement?.nodeID else { continue }
            guard let landed = node.landedCommit else { continue }
            var changed = try await changedFiles(in: landed)
            if !changed.isEmpty, changed.allSatisfy(RepositoryWorkspace.isUIEvidence) {
                changed = try await changedFiles(in: landed + "^")
            }
            let matching = conflicts.intersection(changed)
            guard !matching.isEmpty else { continue }
            let root = state.lineage(of: node.id).last?.ticket ?? node.ticket
            result[root, default: []].formUnion(matching)
        }
        return result.mapValues { $0.sorted() }
    }

    /// A UI leaf lands as a commit that only removes its evidence; its changes are in the parent.
    private func changedFiles(in commit: String) async throws -> [String] {
        try await git(["diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", commit], in: workspace.root)
            .split(separator: "\n").map(String.init)
    }

    private func notify(_ ticketFiles: [String: [String]], main: String) async {
        for (ticket, files) in ticketFiles {
            let marker = "Catch-up conflict with main \(main)"
            guard let tracker else { continue }
            let existing = await tracker.ticket(ticket)
            if existing?.comments.contains(where: { $0.text.contains(marker) }) != true {
                await tracker.adapter.comment(
                    on: ticket,
                    "⚠️ \(marker)\nConflicting files from this work:\n" +
                        files.map { "- \($0)" }.joined(separator: "\n")
                )
            }
            await tracker.adapter.setStatus(of: ticket, to: "Catch-up conflict")
        }
    }

    func projectConflict(_ conflict: CatchUpConflict?) async {
        guard let conflict, let tracker else { return }
        for ticket in conflict.tickets {
            await tracker.adapter.setStatus(of: ticket, to: "Catch-up conflict")
        }
    }

    private func conflictMessage(_ conflict: CatchUpConflict, state: WorkingState) async -> String {
        var owners: [String: [String]] = [:]
        if let mapped = try? await affectedTickets(for: conflict.files, state: state) {
            for (ticket, files) in mapped {
                for file in files { owners[file, default: []].append(ticket) }
            }
        }
        let details = conflict.files.map { file in
            let tickets = owners[file] ?? conflict.tickets
            return "\(file) (\(tickets.joined(separator: ", ")))"
        }.joined(separator: ", ")
        return "Needs human: catch-up to main \(conflict.mainSHA) conflicts in \(details). " +
            "Agents keep working on the previous main."
    }

    private func recordSuccess(main: String, tip: String, method: CatchUpMethod, busy: Set<NodeID>) async throws {
        let state = await ledger.workingState()
        let activeLeaves = state.creationOrder.compactMap { id -> NodeID? in
            guard let node = state.nodes[id],
                  state.lineage(of: id).last?.id == requirement?.nodeID,
                  node.spec.kind == .leaf,
                  node.testsDigest != nil,
                  node.phase != .proven,
                  !node.ticketClosed,
                  node.activeRun == nil, !busy.contains(id) else { return nil }
            return id
        }
        // Catching up throws uncommitted changes away first, so they don't count.
        var intact = Set<NodeID>()
        for id in activeLeaves {
            let directory = workspace.worktree(for: id)
            try await workspace.discardChanges(keeping: [], in: directory)
            if state.nodes[id]?.updatedOtherTestsIntact(in: directory) == true { intact.insert(id) }
        }
        let leaves = try await workspace.catchUpActiveLeaves(activeLeaves)
        var events = [
            LedgerEvent(
                node: requirement?.nodeID,
                by: .adapter("Catch-up"),
                kind: .catchUpSucceeded(main: main, newAgentOSMainTip: tip, method: method)
            ),
        ]
        // Main may have changed other work's tests a leaf updated (rebased, or reset for rework): the lock moves.
        for id in activeLeaves where leaves.rebased.contains(id) || leaves.rework[id] != nil {
            let directory = workspace.worktree(for: id)
            if let renewal = state.nodes[id]?.renewedOtherTestsLock(in: directory, wasIntact: intact.contains(id)) {
                events.append(LedgerEvent(node: id, by: .adapter("Catch-up"), kind: renewal))
            }
        }
        var notifications: [(ticket: String, reason: String)] = []
        for id in activeLeaves {
            guard let files = leaves.rework[id], let node = state.nodes[id] else { continue }
            let detail = files.isEmpty ? "some files" : files.joined(separator: ", ")
            let reason = "merge conflict in \(detail) after catching up with main"
            events += [
                LedgerEvent(node: id, by: .adapter("Catch-up"), kind: .reworkNeeded(reason: reason)),
                LedgerEvent(node: id, by: .adapter("Catch-up"), kind: .phaseChanged(to: .ready)),
            ]
            notifications.append((node.ticket, reason))
        }
        try await ledger.append(events)
        if let tracker {
            for notification in notifications {
                await tracker.adapter.comment(
                    on: notification.ticket,
                    "♻️ Rework: \(notification.reason). The implementation is redone on the latest code; the tests are kept."
                )
            }
        }
    }

    private func addDetachedWorktree(_ directory: URL) async throws {
        try await workspace.addDetachedWorkingCopy(at: directory, from: landingBranch)
    }

    private func removeWorktree(_ directory: URL) async throws {
        try await workspace.removeWorkingCopy(at: directory)
    }

    private func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
        let result = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "merge-base", "--is-ancestor", ancestor, descendant],
            in: workspace.root
        )
        return result.status == 0
    }

    private func revision(_ name: String, in directory: URL? = nil) async throws -> String {
        try await git(["rev-parse", name], in: directory ?? workspace.root)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await workspace.slowGitLog.timing(arguments, in: directory, relativeTo: workspace.storage) {
            try await GitLocks.retryingAfterStaleLock {
                try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
            }
        }
        guard result.status == 0 else {
            throw AgentFailure("git \(arguments.first ?? "") failed: \(result.output.suffix(300))")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func performCatchUp(
        to target: String,
        acceptanceTests: @escaping @Sendable (URL) async throws -> Bool
    ) async throws -> CatchUpOutcome? {
        try await workspace.prepare()
        let oldTip = try await revision(landingBranch)
        let base = try await git(["merge-base", oldTip, target], in: workspace.root)
        let landedCommits = try await commits(from: base, to: oldTip)
        let represented = try await representedCommits(
            landedCommits,
            base: base,
            oldTip: oldTip,
            target: target
        )
        let method: CatchUpReconciliationMethod = represented.count == landedCommits.count ? .move : .merge

        let directory = workspace.worktreesDirectory.appending(path: "catch-up-proposal-\(UUID().uuidString)")
        let proposalStart = method == .move ? target : oldTip
        try await workspace.addDetachedWorkingCopy(at: directory, from: proposalStart)
        do {
            let mappings: [String: String] = [:]
            if method == .merge {
                try await git([
                    "-c", "user.name=AgentOS", "-c", "user.email=agentos@agents.agentos.local",
                    "merge", "-q", "--no-ff", "--no-verify", "-m",
                    "Catch up \(landingBranch) with \(workspace.defaultBranch)", target,
                ], in: directory)
            }

            let newTip = try await revision("HEAD", in: directory)
            guard try await acceptanceTests(directory) else {
                try await removeWorktree(directory)
                return nil
            }
            try await git([
                "update-ref", "-m", "agentos: catch up via \(method.rawValue)",
                "refs/heads/\(landingBranch)", newTip, oldTip,
            ], in: workspace.root)
            try await removeWorktree(directory)
            try await recordSuccess(main: target, tip: newTip, method: .automatic, busy: [])
            try await ledger.append([
                LedgerEvent(
                    node: requirement?.nodeID,
                    by: .adapter("Catch-up"),
                    kind: .caughtUp(
                        targetMain: target,
                        oldLandingTip: oldTip,
                        newLandingTip: newTip,
                        method: method,
                        commitMappings: mappings
                    )
                ),
            ])
            let title = "\(landingBranch) caught up to \(target) (\(method.rawValue))"
            return CatchUpOutcome(
                targetMain: target,
                oldLandingTip: oldTip,
                newLandingTip: newTip,
                method: method,
                commitMappings: mappings,
                status: CatchUpOutcomeStatus(
                    banner: title,
                    scanFinding: Finding(check: "repository.catch-up", severity: .info, title: title)
                )
            )
        } catch {
            try? await removeWorktree(directory)
            throw error
        }
    }

    private func commits(from base: String, to tip: String, in directory: URL? = nil) async throws -> [String] {
        let output = try await git(["rev-list", "--reverse", "\(base)..\(tip)"], in: directory ?? workspace.root)
        return output.split(separator: "\n").map(String.init)
    }

    private func representedCommits(
        _ landed: [String],
        base: String,
        oldTip: String,
        target: String
    ) async throws -> Set<String> {
        if landed.isEmpty {
            return Set(landed)
        }
        if try await isAncestor(oldTip, of: target) {
            return Set(landed)
        }
        let oldTree = try await git(["rev-parse", "\(oldTip)^{tree}"], in: workspace.root)
        let targetTree = try await git(["rev-parse", "\(target)^{tree}"], in: workspace.root)
        if oldTree == targetTree {
            return Set(landed)
        }

        let targetCommits = try await commits(from: base, to: target)
        var targetPatchIDs = Set<String>()
        for commit in targetCommits {
            if let patchID = try await patchID(of: commit) {
                targetPatchIDs.insert(patchID)
            }
        }
        var represented = Set<String>()
        for commit in landed {
            if try await isAncestor(commit, of: target) {
                represented.insert(commit)
            } else if let patchID = try await patchID(of: commit), targetPatchIDs.contains(patchID) {
                represented.insert(commit)
            }
        }
        return represented
    }

    private func patchID(of commit: String) async throws -> String? {
        let result = try await ProcessRunner.run(
            "/bin/sh",
            ["-c", "git show --pretty=format: --no-ext-diff \"$1\" | git patch-id --stable", "patch-id", commit],
            in: workspace.root
        )
        guard result.status == 0 else {
            throw AgentFailure("Could not calculate patch ID for \(commit): \(result.output)")
        }
        return result.output.split(separator: " ").first.map(String.init)
    }

}
