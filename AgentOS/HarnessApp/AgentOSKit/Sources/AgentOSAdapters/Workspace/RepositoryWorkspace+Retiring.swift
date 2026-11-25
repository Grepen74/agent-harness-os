import AgentOSCore
import Foundation

extension RepositoryWorkspace {
    struct WorktreeRegistration: Equatable {
        var path: String
        var locked = false
    }

    func worktreeRegistrations() async throws -> [WorktreeRegistration] {
        var registrations: [WorktreeRegistration] = []
        for field in try await git(["worktree", "list", "--porcelain", "-z"], in: root).split(separator: "\0") {
            if field.hasPrefix("worktree ") {
                registrations.append(WorktreeRegistration(path: String(field.dropFirst("worktree ".count))))
            } else if field == "locked" || field.hasPrefix("locked "), !registrations.isEmpty {
                registrations[registrations.count - 1].locked = true
            }
        }
        return registrations
    }

    /// Takes a working copy out of the repo for good, however big it is. `git worktree remove` deletes the files first,
    /// which can outlast git's time limit on a busy machine and leave the worktree half deleted and still registered.
    /// Instead the folder is renamed into the trash, git forgets it, and only then are its files deleted, in the
    /// background. A worktree someone locked (`git worktree lock`) is left alone, and if git still lists the worktree
    /// afterwards the folder is moved back, so its files are never deleted while git still knows it.
    /// The caller holds `worktreeLock`.
    func retireWorkingCopy(at directory: URL) async throws {
        func registered(_ registrations: [WorktreeRegistration]) -> WorktreeRegistration? {
            registrations.first { Self.samePlace($0.path, directory.path) }
        }
        if let registration = registered(try await worktreeRegistrations()), registration.locked {
            throw AgentFailure("git has locked the worktree at \(directory.path) (git worktree lock), so the harness " +
                "leaves it alone. Unlock or remove it, then add harness:retry.")
        }
        var trashed: URL?
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            let destination = trashDirectory.appending(path: "\(directory.lastPathComponent)-\(UUID().uuidString)")
            try Self.moveAtOnce(directory, to: destination)
            trashed = destination
        }
        do {
            try await git(["worktree", "prune"], in: root)
            guard registered(try await worktreeRegistrations()) == nil else {
                throw AgentFailure("git still lists the worktree at \(directory.path) after pruning, so its files " +
                    "were kept. Check `git worktree list`, then add harness:retry.")
            }
        } catch {
            if let trashed { try? Self.moveAtOnce(trashed, to: directory) }
            throw error
        }
        if let trashed { await trash.delete(trashed) }
    }

    /// A detached working copy of `start`, e.g. for catch-up: added one at a time with the leaves' worktrees.
    func addDetachedWorkingCopy(at directory: URL, from start: String) async throws {
        try await worktreeLock.withPermit {
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await git(["worktree", "add", "-q", "--detach", directory.path, start], in: root)
        }
    }

    func removeWorkingCopy(at directory: URL) async throws {
        try await worktreeLock.withPermit { try await retireWorkingCopy(at: directory) }
    }

    /// Prunes, then deletes what is left in the trash, e.g. when the app quit before deleting it. Under the lock: a
    /// retirement holds it until git has forgotten its working copy, so everything in the trash then is forgotten,
    /// except after a crash between moving and pruning. So when git still lists an unlocked worktree whose folder is
    /// gone (pruning didn't work), it keeps the trash.
    func pruneAndEmptyTrash() async throws {
        try await worktreeLock.withPermit {
            try await git(["worktree", "prune"], in: root)
            let items = (try? FileManager.default.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil)) ?? []
            guard !items.isEmpty else { return }
            // A locked one may be on a disk that isn't there: git keeps those on purpose, and the trash never had it.
            let missing = try await worktreeRegistrations()
                .filter { !$0.locked && !FileManager.default.fileExists(atPath: $0.path) }
            guard missing.isEmpty else {
                await trash.note("kept the trash: git still lists worktrees that are gone after pruning: "
                    + missing.map(\.path).joined(separator: ", "))
                return
            }
            for item in items { await trash.delete(item) }
        }
    }

    /// A rename, never a copy: across disks moving would take as long as deleting.
    static func moveAtOnce(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) != 0 else { return }
        let code = errno
        if code == EXDEV {
            throw AgentFailure("Can't move \(source.path) to \(destination.deletingLastPathComponent().path) at once: " +
                "they are on different disks. Keep the harness's storage folder on one disk.")
        }
        throw AgentFailure("Can't move \(source.path) to \(destination.path): \(String(cString: strerror(code)))")
    }

    /// git lists a worktree by its real path (/private/var/… for /var/…); the folder itself may be gone already.
    static func samePlace(_ first: String, _ second: String) -> Bool {
        func canonical(_ path: String) -> String {
            let url = URL(filePath: path).standardizedFileURL
            return url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent).path
        }
        return canonical(first) == canonical(second)
    }
}

/// Deletes retired working copies one at a time, in the background, without a time limit. Failures are written to
/// `log`, and the folder stays in the trash, deleted again on the next start. Working copies that couldn't be retired
/// at all are noted there too.
actor WorktreeTrash {
    nonisolated let log: URL
    private var queue: [URL] = []
    private var worker: Task<Void, Never>?
    private var current: URL?
    private(set) var failures: [String] = []

    init(log: URL) {
        self.log = log
    }

    func delete(_ item: URL) {
        guard !queue.contains(item), item != current else { return }
        queue.append(item)
        if worker == nil {
            worker = Task.detached(priority: .background) { [weak self] in await self?.work() }
        }
    }

    /// Returns once everything queued so far is deleted or has failed.
    func emptied() async {
        while let worker { await worker.value }
    }

    private func next() -> URL? {
        guard !queue.isEmpty else {
            worker = nil
            current = nil
            return nil
        }
        current = queue.removeFirst()
        return current
    }

    private func work() async {
        while let item = next() {
            if let failure = await Self.remove(item) {
                note("couldn't delete \(item.path): \(failure)")
            }
        }
    }

    private nonisolated static func remove(_ item: URL) async -> String? {
        do {
            try FileManager.default.removeItem(at: item)
            return nil
        } catch {
            return FileManager.default.fileExists(atPath: item.path) ? error.localizedDescription : nil
        }
    }

    /// Something that couldn't be cleaned up, for `log`.
    func note(_ problem: String) {
        let line = "\(Date.now.ISO8601Format()) \(problem)"
        failures.append(line)
        AgentLog.append(line, to: log)
    }
}
