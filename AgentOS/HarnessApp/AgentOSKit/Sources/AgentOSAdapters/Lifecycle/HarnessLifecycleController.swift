import AgentOSCore
import Foundation

/// Something the app runs rounds on: a reconciler itself or a `RepositorySession` (which catches up first). The
/// reconciler owns the node steps that keep running across rounds.
public protocol HarnessSession: AnyObject, Sendable {
    var reconciler: Reconciler { get }
    func step() async -> RoundReport
}

extension Reconciler: HarnessSession {
    public nonisolated var reconciler: Reconciler { self }
    public func step() async -> RoundReport { await runRound() }
}

extension RepositorySession: HarnessSession {}

/// One window's harness lifecycle, shared by the repository and simulator windows. Node steps keep running
/// across rounds, so stopping means more than ending the Run loop:
/// - `setRunning(false)` (Pause) only ends the loop: steps already started carry on, and resuming doesn't
///   start them again.
/// - `stopAndWait()` also waits for every step the reconciler owns, through its cleanup and durable finish.
/// - `replaceSession` drains the old session that way before the new one is made, so nothing from the old
///   session writes after the replacement (or a ledger restore, or a storage reset) begins.
/// - `close()` and `shutdown(reason:)` cancel the steps, record why, and wait for their cleanup.
@MainActor
public final class HarnessLifecycleController {
    public private(set) var session: (any HarnessSession)?
    public var reconciler: Reconciler? { session?.reconciler }
    public private(set) var isRunning = false
    /// A round is under way.
    public private(set) var isBusy = false
    /// Waiting for steps from earlier rounds to finish (stop and wait, or a replacement).
    public private(set) var isDraining = false
    public private(set) var isShutDown = false
    /// A `replaceSession` is under way; the next one, and shutdown, wait for it.
    public private(set) var isReplacing = false
    /// How long Run waits between rounds.
    public var interval: Duration
    /// What Run does each interval; by default one `step()`. A window sets its own, e.g. to also show the report.
    public var runStep: (@MainActor () async -> Void)?
    private var runTask: Task<Void, Never>?

    public init(session: (any HarnessSession)?, interval: Duration = .seconds(2)) {
        self.session = session
        self.interval = interval
    }

    public convenience init(reconciler: Reconciler, interval: Duration = .seconds(2)) {
        self.init(session: reconciler, interval: interval)
    }

    /// One round, unless one is already under way, the session is draining or shut down (then an empty report).
    /// It returns without waiting for the agents it starts.
    @discardableResult
    public func step() async -> RoundReport {
        guard !isBusy, !isDraining, !isShutDown, let session else { return RoundReport() }
        isBusy = true
        let report = await session.step()
        isBusy = false
        if report.safeStop != nil { setRunning(false) }
        return report
    }

    /// Run = a round every `interval`. Pausing doesn't cancel steps already started.
    public func setRunning(_ running: Bool) {
        isRunning = running && session != nil && !isShutDown
        runTask?.cancel()
        runTask = nil
        guard isRunning else { return }
        runTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                if let runStep = self.runStep { await runStep() } else { await self.step() }
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    /// Stops Run, then waits for a round under way and for every step the session owns, including steps
    /// started by earlier rounds, through their cleanup and durable finish.
    public func stopAndWait() async {
        setRunning(false)
        isDraining = true
        await waitForRound()
        await session?.reconciler.waitForAgents()
        isDraining = false
    }

    /// Drains the current session (`stopAndWait`), then makes the next one: `make` is the first point allowed to
    /// touch the old session's storage. Returning nil leaves no session (e.g. readiness blockers). Replacements
    /// run one at a time, rounds stay disabled until the new session is installed, and after shutdown nothing
    /// is replaced (`make` isn't called).
    public func replaceSession(_ make: () async throws -> (any HarnessSession)?) async throws {
        while isReplacing { try? await Task.sleep(for: .milliseconds(20)) }
        guard !isShutDown else { return }
        isReplacing = true
        defer { isReplacing = false }
        await stopAndWait()
        guard !isShutDown else { return }
        session = nil
        session = try await make()
    }

    /// The window closed: steps are cancelled with that reason, and this returns after their cleanup.
    public func close() async {
        await shutdown(reason: "repository window closed")
    }

    /// Cancels every step the session owns, recording `reason` as each run's finish, and waits for their
    /// cleanup. No round runs afterwards. A replacement under way finishes first, so its session is shut down too.
    public func shutdown(reason: String) async {
        isShutDown = true
        setRunning(false)
        while isReplacing { try? await Task.sleep(for: .milliseconds(20)) }
        await session?.reconciler.shutdown(reason: reason)
        await waitForRound()
        await session?.reconciler.waitForAgents()
    }

    private func waitForRound() async {
        while isBusy { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
