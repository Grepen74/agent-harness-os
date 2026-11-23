import AgentOSCore
import Foundation
import Synchronization

extension RepositoryWorkspace {
    private var originDefaultBranch: String {
        defaultBranch.hasPrefix("origin/") ? String(defaultBranch.dropFirst("origin/".count)) : defaultBranch
    }

    /// Selects one fetched commit for all main consumers, without touching any local branch or checkout.
    public func refreshMain(publishing: Bool) async throws -> String? {
        try await mainReferenceLock.withPermit {
            guard publishing else {
                mainReference.select(nil)
                return nil
            }
            let branch = originDefaultBranch
            let ref = "refs/remotes/origin/\(branch)"
            let previous = try await remoteMainTip(ref)
            mainReference.beginWatching(previous)
            var failure: String?
            do {
                let result = try await ProcessRunner.run("/usr/bin/env", [
                    "git", "fetch", "--no-tags", "--no-write-fetch-head", "--no-auto-maintenance",
                    "--recurse-submodules=no", "origin", "+refs/heads/\(branch):\(ref)",
                ], in: root, timeout: .seconds(120))
                if result.status != 0 { failure = result.output.trimmingCharacters(in: .whitespacesAndNewlines) }
            } catch {
                failure = String(describing: error)
            }
            guard let commit = try await remoteMainTip(ref) else {
                throw AgentFailure("Could not fetch origin/\(branch): \(failure ?? "remote ref is missing"). " +
                    "No last fetched commit is available. Restore origin access, then run again.")
            }
            mainReference.select(commit)
            if let failure {
                return "Could not fetch origin/\(branch): \(failure). " +
                    "Using the last fetched commit \(commit.prefix(8)). Check origin access; the next round retries automatically."
            }
            mainReference.recordFetch(commit)
            return nil
        }
    }

    public func mainTip() async throws -> String { try await localMainTip() }

    private func remoteMainTip(_ ref: String) async throws -> String? {
        let result = try await ProcessRunner.run(
            "/usr/bin/env", ["git", "rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: root)
        if result.status == 1 { return nil }
        guard result.status == 0 else { throw AgentFailure("Could not read \(ref): \(result.output)") }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only ref values observed before the first fetch or written by a successful harness fetch are
    /// normalised. Other remote refs and unexpected edits to this ref still trip the agent's git-state watch.
    func watchedRefs() async throws -> String {
        try await mainReferenceLock.withPermit {
            let refs = try await git(["for-each-ref", "--format=%(objectname) %(refname) %(symref)"], in: root)
            let ref = "refs/remotes/origin/\(originDefaultBranch)"
            return refs.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count >= 2 else { return String(line) }
                if parts.count == 3 { return "symbolic:\(parts[2]) \(parts[1])" }
                guard parts[1] == ref else { return "\(parts[0]) \(parts[1])" }
                return mainReference.watchedValue(String(parts[0]), ref: ref)
            }.joined(separator: "\n")
        }
    }
}

final class MainReferenceSelection: Sendable {
    private struct State {
        var commit: String?
        var watching = false
        var original: String?
        var fetched: Set<String> = []
    }
    private let state = Mutex(State())

    var commit: String? { state.withLock { $0.commit } }

    func select(_ commit: String?) { state.withLock { $0.commit = commit } }

    func beginWatching(_ previous: String?) {
        state.withLock {
            guard !$0.watching else { return }
            $0.watching = true
            $0.original = previous
            if let previous { $0.fetched.insert(previous) }
        }
    }

    func recordFetch(_ commit: String) { state.withLock { _ = $0.fetched.insert(commit) } }

    func watchedValue(_ commit: String, ref: String) -> String? {
        state.withLock {
            guard $0.fetched.contains(commit) else { return "\(commit) \(ref)" }
            return $0.original.map { "\($0) \(ref)" }
        }
    }
}
