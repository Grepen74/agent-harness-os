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

actor CatchUpCoordinator {
    private let workspace: RepositoryWorkspace
    private let ledger: Ledger
    private let tracker: any TicketBoard

    init(workspace: RepositoryWorkspace, ledger: Ledger, tracker: any TicketBoard) {
        self.workspace = workspace
        self.ledger = ledger
        self.tracker = tracker
    }

    func reconcile(force: Bool = false) async -> String? {
        do {
            try await workspace.prepare()
            let main = try await revision(workspace.defaultBranch)
            let landing = try await revision(workspace.landingBranch)
            let state = await ledger.workingState()

            if let conflict = state.catchUpConflict,
               try await isAncestor(conflict.mainSHA, of: landing) {
                try await setManualMergeAid(files: [], enabled: false)
                try await recordSuccess(main: conflict.mainSHA, tip: landing, method: .manual)
                return "Manual catch-up to \(conflict.mainSHA.prefix(8)) recognized"
            }

            if try await isAncestor(main, of: landing) {
                await projectConflict(state.catchUpConflict)
                return nil
            }
            if !force, state.catchUpConflict?.mainSHA == main {
                await projectConflict(state.catchUpConflict)
                return nil
            }

            if let conflict = state.catchUpConflict {
                try await setManualMergeAid(files: conflict.files, enabled: false)
            }
            let result = try await attemptMerge(main: main, landing: landing)
            switch result {
            case .success(let tip):
                try await setManualMergeAid(files: [], enabled: false)
                try await recordSuccess(main: main, tip: tip, method: .automatic)
                return "Caught agentos/main up to \(main.prefix(8))"
            case .conflict(let files):
                let ticketFiles = try await affectedTickets(for: files, state: state)
                let tickets = ticketFiles.keys.sorted()
                try await ledger.append([
                    LedgerEvent(
                        node: nil,
                        by: .adapter("Catch-up"),
                        kind: .catchUpConflicted(main: main, files: files.sorted(), tickets: tickets)
                    ),
                ])
                let conflict = CatchUpConflict(mainSHA: main, files: files.sorted(), tickets: tickets)
                try await setManualMergeAid(files: files, enabled: true)
                await notify(ticketFiles, main: main)
                await projectConflict(conflict)
                return "Catch-up to \(main.prefix(8)) conflicted"
            }
        } catch {
            return "⚠️ Catch-up failed: \(error)"
        }
    }

    func status() async -> CatchUpStatus {
        let state = await ledger.workingState()
        guard let conflict = state.catchUpConflict else {
            return CatchUpStatus(
                conflict: nil,
                lastSuccess: state.lastCatchUpSuccess,
                banner: nil,
                attentionItems: [],
                scanFinding: nil
            )
        }
        let message = await conflictMessage(conflict, state: state)
        let behind = (try? await git(["rev-list", "--count", "\(workspace.landingBranch)..\(workspace.defaultBranch)"],
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
            title: "agentos/main is \(behind) commit\(behind == "1" ? "" : "s") behind main: catch-up conflict in \(conflict.files.count) files"
        )
        return CatchUpStatus(
            conflict: conflict,
            lastSuccess: state.lastCatchUpSuccess,
            banner: banner,
            attentionItems: [item],
            scanFinding: finding
        )
    }

    func conflictDiff() async throws -> String {
        guard let conflict = await ledger.workingState().catchUpConflict else {
            throw AgentFailure("There is no catch-up conflict.")
        }
        let directory = workspace.worktreesDirectory.appending(path: "catch-up-diff-\(UUID().uuidString)")
        try await setManualMergeAid(files: conflict.files, enabled: false)
        try await addDetachedWorktree(directory)
        _ = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "merge", "--no-commit", "--no-ff", conflict.mainSHA],
            in: directory
        )
        let diff = try await git(["diff", "--no-ext-diff"], in: directory)
        try await removeWorktree(directory)
        try await setManualMergeAid(files: conflict.files, enabled: true)
        return diff
    }

    func openInTerminal() async throws -> URL {
        guard let conflict = await ledger.workingState().catchUpConflict else {
            throw AgentFailure("There is no catch-up conflict.")
        }
        let directory = workspace.worktreesDirectory.appending(path: "catch-up-\(conflict.mainSHA.prefix(12))")
        if FileManager.default.fileExists(atPath: directory.path) {
            try await removeWorktree(directory)
        }
        try await setManualMergeAid(files: conflict.files, enabled: false)
        try await addDetachedWorktree(directory)
        let result = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "merge", "--no-commit", "--no-ff", conflict.mainSHA],
            in: directory
        )
        guard result.status != 0 else {
            throw AgentFailure("The recorded catch-up no longer conflicts.")
        }
        try await setManualMergeAid(files: conflict.files, enabled: true)
        return directory
    }

    private enum MergeAttempt {
        case success(String)
        case conflict([String])
    }

    private func attemptMerge(main: String, landing: String) async throws -> MergeAttempt {
        if try await isAncestor(landing, of: main) {
            try await git(["update-ref", "refs/heads/\(workspace.landingBranch)", main, landing], in: workspace.root)
            return .success(main)
        }

        let directory = workspace.worktreesDirectory.appending(path: "catch-up-attempt-\(UUID().uuidString)")
        try await addDetachedWorktree(directory)
        let merge = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "merge", "--no-commit", "--no-ff", main],
            in: directory
        )
        guard merge.status == 0 else {
            let files = try await git(["diff", "--name-only", "--diff-filter=U"], in: directory)
                .split(separator: "\n").map(String.init)
            try await removeWorktree(directory)
            return .conflict(files)
        }
        try await git([
            "-c", "user.name=AgentOS", "-c", "user.email=agentos@agents.agentos.local",
            "commit", "-q", "--no-verify", "-m", "Catch up agentos/main with \(workspace.defaultBranch)",
        ], in: directory)
        let tip = try await revision("HEAD", in: directory)
        try await git(["update-ref", "refs/heads/\(workspace.landingBranch)", tip, landing], in: workspace.root)
        try await removeWorktree(directory)
        return .success(tip)
    }

    private func affectedTickets(
        for conflictFiles: [String],
        state: WorkingState
    ) async throws -> [String: [String]] {
        var result: [String: Set<String>] = [:]
        let conflicts = Set(conflictFiles)
        for node in state.nodes.values where node.phase == .proven {
            guard let commit = node.landedCommit else { continue }
            let changed = try await git(
                ["diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", commit],
                in: workspace.root
            ).split(separator: "\n").map(String.init)
            let matching = conflicts.intersection(changed)
            guard !matching.isEmpty else { continue }
            let root = state.lineage(of: node.id).last?.ticket ?? node.ticket
            result[root, default: []].formUnion(matching)
        }
        return result.mapValues { $0.sorted() }
    }

    private func notify(_ ticketFiles: [String: [String]], main: String) async {
        for (ticket, files) in ticketFiles {
            let marker = "Catch-up conflict with main \(main)"
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

    private func projectConflict(_ conflict: CatchUpConflict?) async {
        guard let conflict else { return }
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

    private func recordSuccess(main: String, tip: String, method: CatchUpMethod) async throws {
        try await ledger.append([
            LedgerEvent(
                node: nil,
                by: .adapter("Catch-up"),
                kind: .catchUpSucceeded(main: main, newAgentOSMainTip: tip, method: method)
            ),
        ])
    }

    private func setManualMergeAid(files: [String], enabled: Bool) async throws {
        let common = try await git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            in: workspace.root
        )
        let attributes = URL(filePath: common).appending(path: "info/attributes")
        let start = "# agentos catch-up conflict"
        let end = "# end agentos catch-up conflict"
        let existing = (try? String(contentsOf: attributes, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.firstIndex(of: start), let last = lines[first...].firstIndex(of: end) {
            lines.removeSubrange(first...last)
        }
        while lines.last == "" { lines.removeLast() }
        if enabled {
            lines.append(start)
            lines += files.sorted().map { "\($0) merge=union" }
            lines.append(end)
            _ = try await git(
                ["config", "branch.\(workspace.landingBranch).mergeOptions", "--no-commit"],
                in: workspace.root
            )
        } else {
            let result = try await ProcessRunner.run(
                "/usr/bin/env",
                ["git", "config", "--unset", "branch.\(workspace.landingBranch).mergeOptions"],
                in: workspace.root
            )
            if result.status != 0 && result.status != 5 {
                throw AgentFailure("Could not clear catch-up merge options: \(result.output)")
            }
        }
        let contents = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try contents.write(to: attributes, atomically: true, encoding: .utf8)
    }

    private func addDetachedWorktree(_ directory: URL) async throws {
        try FileManager.default.createDirectory(
            at: workspace.worktreesDirectory,
            withIntermediateDirectories: true
        )
        try await git(
            ["worktree", "add", "-q", "--detach", directory.path, workspace.landingBranch],
            in: workspace.root
        )
    }

    private func removeWorktree(_ directory: URL) async throws {
        try await git(["worktree", "remove", "--force", directory.path], in: workspace.root)
        try await git(["worktree", "prune"], in: workspace.root)
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
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
        guard result.status == 0 else {
            throw AgentFailure("git \(arguments.first ?? "") failed: \(result.output.suffix(300))")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
