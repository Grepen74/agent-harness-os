import AgentOSCore
import AppKit

/// Keeps a window current while agents work: every ledger event (a run starting, a submission, evidence)
/// refreshes the panes right away, instead of only after a whole round. Events that come in a burst
/// refresh once.
@MainActor
final class LedgerFollower {
    private var task: Task<Void, Never>?
    private var scheduled = false

    func follow(_ ledger: Ledger, refresh: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            for await _ in await ledger.subscribe() {
                guard let self else { return }
                guard !scheduled else { continue }
                scheduled = true
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    self.scheduled = false
                    await refresh()
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Looking at a leaf's working copy and its agent's log, shared by the simulator and real repos.
enum WorkingCopy {
    static func existing(_ url: URL) -> URL? { FileManager.default.fileExists(atPath: url.path) ? url : nil }

    static func agentLog(in artifacts: URL, node: NodeID, run: RunID) -> URL? {
        existing(artifacts.appending(path: AgentLog.fileName(node: node, run: run)))
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Opens the working copy's workspace, project or package in Xcode, or the folder if it has none.
    static func openInXcode(_ folder: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let project = names.first { $0.hasSuffix(".xcworkspace") } ?? names.first { $0.hasSuffix(".xcodeproj") }
            ?? names.first { $0 == "Package.swift" }
        let url = project.map { folder.appending(path: $0) } ?? folder
        guard let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: xcode, configuration: NSWorkspace.OpenConfiguration())
    }
}
