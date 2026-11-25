import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_110Tests {
    final class Fixture: Sendable {
        static let fetchError = "GH110 authentication rejected"
        let directory: URL
        let repo: URL
        let origin: URL
        let defaultBranch: String
        let initial: String
        let workspace: RepositoryWorkspace
        let ledger: Ledger
        let tracker = Tracker()
        let agents = Agents()
        let reconciler: Reconciler
        private let uploadPack: URL
        private let fetchLog: URL

        init(publishing: Bool, defaultBranch: String = "main") async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "GH-110-\(UUID().uuidString)")
            repo = directory.appending(path: "checkout")
            origin = directory.appending(path: "origin.git")
            uploadPack = directory.appending(path: "record-upload-pack")
            fetchLog = directory.appending(path: "fetches")
            self.defaultBranch = defaultBranch
            let cleanup = directory
            var initialized = false
            defer {
                if !initialized {
                    do { try FileManager.default.removeItem(at: cleanup) }
                    catch { Issue.record("Could not clean up the incomplete GH-110 fixture: \(error)") }
                }
            }
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try await Self.git(["init", "-q", "-b", defaultBranch], in: repo)
            try await Self.git(["config", "user.name", "GH-110 fixture"], in: repo)
            try await Self.git(["config", "user.email", "gh110@example.invalid"], in: repo)
            try "base\n".write(to: repo.appending(path: "base.txt"), atomically: true, encoding: .utf8)
            try await Self.git(["add", "base.txt"], in: repo)
            try await Self.git(["commit", "-q", "-m", "initial"], in: repo)
            initial = try await Self.git(["rev-parse", "HEAD"], in: repo)
            try await Self.git(["clone", "-q", "--bare", "--no-hardlinks", repo.path, origin.path], in: directory)
            try await Self.git(["remote", "add", "origin", origin.path], in: repo)
            try await Self.git(["fetch", "-q", "origin", defaultBranch], in: repo)
            try await Self.git(["remote", "set-head", "origin", defaultBranch], in: repo)
            try await Self.git(["switch", "-q", "-c", "personal-checkout"], in: repo)
            let uploadCommand = "'" + uploadPack.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            try await Self.git(["config", "remote.origin.uploadpack", uploadCommand], in: repo)
            ledger = try Ledger()
            let config = RepoConfig(test: .init(command: "true"),
                                    leafTests: .init(target: "AppTests", folder: "Tests/AppTests"))
            workspace = try RepositoryWorkspace(
                root: repo, storage: directory.appending(path: "storage"), config: config,
                landingBranch: "agentos/<ticket key>", defaultBranch: defaultBranch)
            var policy = Policy(pullRequests: publishing)
            policy.avoidOverlappingWork = false
            policy.review.level = .none
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: External(), workspace: workspace,
                artifacts: FileArtifactStore(directory: directory.appending(path: "artifacts")),
                checks: Checks(), team: AgentTeam(name: "GH-110 gated team", decomposer: agents,
                                                 testAuthor: agents, implementer: agents),
                policy: policy, requirementBranches: workspace)
            try setFetchFailure(false)
            try await git(["fetch", "-q", "origin", defaultBranch])
            try #require(try fetchCount() == 1, "Verify that a real local fetch invokes the fetch recorder.")
            try FileManager.default.removeItem(at: fetchLog)
            #expect(try await git(["show", "\(initial):base.txt"]) == "base",
                    "Verify the fixture's git helper against a known committed file.")
            #expect(try await revision("refs/remotes/origin/\(defaultBranch)") == initial)
            #expect(try fetchCount() == 0)
            initialized = true
        }

        func branch(_ requirement: NodeIdentity) -> String { "agentos/\(requirement.ticketKey)" }

        @discardableResult
        func round(waitForAgents: Bool = true) async throws -> RoundReport {
            let report = try await withHangGuard("GH-110 reconciler round") {
                await self.reconciler.runRound(waitForAgents: waitForAgents)
            }
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
            return report
        }

        func roundsUntil(_ what: String, _ predicate: @escaping @Sendable (WorkingState) -> Bool) async throws {
            try await withHangGuard(what) {
                while true {
                    try Task.checkCancellation()
                    let report = try await self.round()
                    if predicate(await self.ledger.workingState()) { return }
                    try #require(!report.isIdle, "The round became idle before \(what).")
                }
            }
        }

        func recordBaseline(_ commit: String) async throws {
            try await ledger.record(Baseline(commit: commit, passed: true, summary: "fixture passed", seconds: 0, log: nil))
        }

        func addRequirement(_ name: String, proven: Bool = false, from base: String? = nil) async throws -> NodeIdentity {
            let identity = NodeIdentity(ticketKey: "GH-110-\(name)", nodeID: "root-\(name)")
            let root = NodeSpec(id: identity.nodeID, kind: .composite, title: name,
                                intent: "Track default branch", acceptanceCriteria: ["Use the selected main"])
            let leaf = NodeSpec(id: "leaf-\(name)", parent: root.id, kind: .leaf, title: "\(name) work",
                                intent: "Keep work on its requirement", acceptanceCriteria: ["Preserve requirement work"])
            let commit = base ?? initial
            try await git(["branch", "--no-track", branch(identity), commit])
            try await ledger.append([
                LedgerEvent(node: root.id, by: .human("Person"), kind: .nodeCreated(spec: root, ticket: identity.ticketKey)),
                LedgerEvent(node: root.id, by: .reconciler, kind: .phaseChanged(to: proven ? .proven : .split)),
                LedgerEvent(node: root.id, by: .reconciler, kind: .requirementBranchCreated(branch: branch(identity), from: commit)),
                LedgerEvent(node: root.id, by: .reconciler, kind: .requirementBranchObserved(
                    branch: branch(identity), tip: commit, main: initial, containedInMain: false)),
                LedgerEvent(node: leaf.id, by: .human("Person"), kind: .nodeCreated(spec: leaf, ticket: leaf.id)),
                LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: proven ? .proven : .specified)),
            ])
            return identity
        }

        func addDependent(on requirement: NodeIdentity, createBranch: Bool) async throws -> NodeID {
            let root = NodeSpec(id: "dependent-root", kind: .composite, title: "Dependent requirement",
                                intent: "Use delivered work", acceptanceCriteria: ["Wait for a merge"])
            let leaf = NodeSpec(id: "dependent-leaf", parent: root.id, kind: .leaf, title: "Dependent work",
                                intent: "Use another requirement", acceptanceCriteria: ["Build with delivered work"],
                                dependsOn: [requirement.ticketKey])
            try await ledger.append([
                LedgerEvent(node: root.id, by: .human("Person"), kind: .nodeCreated(spec: root, ticket: "GH-110-DEPENDENT")),
                LedgerEvent(node: root.id, by: .reconciler, kind: .phaseChanged(to: .split)),
                LedgerEvent(node: leaf.id, by: .human("Person"), kind: .nodeCreated(spec: leaf, ticket: "GH-110-DEPENDENT-LEAF")),
                LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
                LedgerEvent(node: leaf.id, by: .reconciler, kind: .flagSet(.blocked, reason: "Waiting for \(requirement.ticketKey)")),
            ])
            if createBranch {
                try await git(["branch", "--no-track", "agentos/GH-110-DEPENDENT", initial])
                try await ledger.append([LedgerEvent(node: root.id, by: .reconciler,
                    kind: .requirementBranchCreated(branch: "agentos/GH-110-DEPENDENT", from: initial))])
            }
            return leaf.id
        }

        func recordLanding(_ requirement: NodeIdentity, commit: String) async throws {
            let leaf = try #require(await ledger.workingState().requirementLeaves(for: requirement.nodeID).first)
            try await ledger.append([LedgerEvent(node: leaf.id, by: .reconciler, kind: .landed(commit: commit))])
        }

        func prepareBuilder(_ requirement: NodeIdentity) async throws -> NodeID {
            let leaf = try #require(await ledger.workingState().requirementLeaves(for: requirement.nodeID).first)
            _ = try await workspace.prepareRequirementBranch(for: requirement, leaves: [leaf.id])
            let checkout = try await workspace.createWorktree(for: leaf.id)
            let folder = checkout.appending(path: workspace.testFolder(for: leaf.spec))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "acceptance fixture\n".write(to: folder.appending(path: "Acceptance.txt"), atomically: true, encoding: .utf8)
            _ = try #require(try await workspace.commitAll(in: checkout, message: "tests", author: "test-author"))
            try await ledger.append([
                LedgerEvent(node: leaf.id, by: .reconciler, kind: .testsFixed(digest: Hashing.digest(of: folder))),
                LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
                LedgerEvent(node: requirement.nodeID, by: .human("Person"), kind: .gateOpened(.build)),
            ])
            try await recordBaseline(initial)
            return leaf.id
        }

        func advanceOrigin(file: String) async throws -> String {
            try await commit(file: file, ref: "refs/heads/\(defaultBranch)", repository: origin, bare: true)
        }

        func advanceLocalDefault(file: String) async throws -> String {
            try await commit(file: file, ref: "refs/heads/\(defaultBranch)", repository: repo)
        }

        func advanceRequirement(_ requirement: NodeIdentity, file: String) async throws -> String {
            try await commit(file: file, ref: "refs/heads/\(branch(requirement))", repository: repo)
        }

        func mergeIntoOrigin(_ commit: String) async throws {
            // Transfer the requirement's objects between isolated local repositories, with no network or push.
            try await Self.git(["--git-dir", origin.path, "fetch", "-q", repo.path, commit], in: directory)
            try await Self.git(["--git-dir", origin.path, "update-ref", "refs/heads/\(defaultBranch)", commit], in: directory)
        }

        private func commit(file: String, ref: String, repository: URL, bare: Bool = false) async throws -> String {
            let prefix = bare ? ["--git-dir", repository.path] : []
            let base = try await Self.git(prefix + ["rev-parse", ref], in: repository)
            let checkout = directory.appending(path: "writer-\(UUID().uuidString)")
            try await Self.git(prefix + ["worktree", "add", "-q", "--detach", checkout.path, base], in: repository)
            try "\(file)\n".write(to: checkout.appending(path: file), atomically: true, encoding: .utf8)
            try await Self.git(["add", file], in: checkout)
            try await Self.git(["-c", "user.name=GH-110", "-c", "user.email=gh110@example.invalid",
                                "commit", "-q", "-m", file], in: checkout)
            let commit = try await Self.git(["rev-parse", "HEAD"], in: checkout)
            try await Self.git(prefix + ["update-ref", ref, commit, base], in: repository)
            try await Self.git(prefix + ["worktree", "remove", checkout.path], in: repository)
            return commit
        }

        func setFetchFailure(_ failed: Bool) throws {
            let escaped = fetchLog.path.replacingOccurrences(of: "'", with: "'\\''")
            let outcome = failed
                ? "printf '\(Self.fetchError)\\n' >&2\nexit 1\n"
                : "exec /usr/bin/git-upload-pack \"$@\"\n"
            try ("#!/bin/sh\nprintf 'fetch\\n' >> '\(escaped)'\n" + outcome)
                .write(to: uploadPack, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uploadPack.path)
        }

        func fetchCount() throws -> Int {
            guard FileManager.default.fileExists(atPath: fetchLog.path) else { return 0 }
            return try String(contentsOf: fetchLog, encoding: .utf8).split(separator: "\n").count
        }

        func verifyFetchFailure() async throws {
            let result = try await ProcessRunner.run("/usr/bin/git", ["fetch", "-q", "origin", defaultBranch], in: repo)
            try #require(result.status != 0, "The failure fixture must actually reject a real Git fetch.")
            try #require(result.output.contains(Self.fetchError), "The failure fixture must report its diagnostic through Git.")
        }

        struct PersonalState: Equatable {
            let defaultTip: String
            let checkedOutBranch: String
            let head: String
            let status: String
            let indexEntries: String
            let stagedDiff: String
            let files: [String: Data]
        }

        func personalState() async throws -> PersonalState {
            var files: [String: Data] = [:]
            for name in ["base.txt", "staged.txt", "untracked.txt"] {
                files[name] = try Data(contentsOf: repo.appending(path: name))
            }
            return try await PersonalState(
                defaultTip: revision("refs/heads/\(defaultBranch)"), checkedOutBranch: git(["branch", "--show-current"]),
                head: revision("HEAD"), status: git(["status", "--porcelain=v1", "--untracked-files=all"]),
                indexEntries: git(["ls-files", "--stage", "-z"]), stagedDiff: git(["diff", "--cached", "--binary"]),
                files: files)
        }

        func revision(_ ref: String) async throws -> String { try await git(["rev-parse", "--verify", ref]) }

        @discardableResult
        func git(_ arguments: [String]) async throws -> String { try await Self.git(arguments, in: repo) }

        @discardableResult
        private static func git(_ arguments: [String], in directory: URL) async throws -> String {
            let result = try await ProcessRunner.run("/usr/bin/git", arguments, in: directory)
            try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func cleanUp() {
            agents.release.open()
            do { try FixtureFolder.remove(directory) }
            catch { Issue.record("Could not remove GH-110's isolated fixture: \(error)") }
        }
    }

    actor Tracker: TrackerAdapter {
        private(set) var statuses: [String: String] = [:]
        private(set) var mainAtSignalIntake: [String] = []
        private var mainProbe: (@Sendable () async throws -> String)?
        func observeMainAtSignalIntake(_ probe: @escaping @Sendable () async throws -> String) { mainProbe = probe }
        func pendingSignals() async -> [Signal] {
            if let mainProbe {
                do { mainAtSignalIntake.append(try await mainProbe()) }
                catch { Issue.record("Could not observe main at signal intake: \(error)") }
            }
            return []
        }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async {}
        func comment(on key: String, _ text: String) async {}
        func setStatus(of key: String, to status: String) async { statuses[key] = status }
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("GH-110's fixture supplies its own hierarchy.")
        }
    }

    struct External: ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
    }

    struct Checks: CheckRunner {
        func runChecks(in directory: URL, only suite: String?) async -> CheckOutput {
            CheckOutput(passed: true, summary: "fixture checks passed", log: "fixture checks passed")
        }
    }

    struct Agents: Decomposer, TestAuthor, Implementer {
        let started = TestGate()
        let release = TestGate()
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH-110's fixture must not start a decomposer.")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-110's fixture must not start a test author.")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            started.open()
            try await release.wait()
            try "implemented\n".write(to: task.directory.appending(path: "builder-feature.txt"),
                                      atomically: true, encoding: .utf8)
            return AgentReport()
        }
    }
}
