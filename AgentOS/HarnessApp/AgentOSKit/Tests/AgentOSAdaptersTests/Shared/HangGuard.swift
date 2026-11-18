import Foundation
import Synchronization
import Testing

/// Helpers that keep tests independent of timing. A test waits for what it needs, never for a fixed time: it holds
/// fake agents at a `TestGate` it opens itself, or waits with `eventually` for a condition. Timeouts here only catch
/// hangs, so a broken harness fails the test instead of hanging the suite; they are long on purpose and must never
/// decide whether a healthy but slow run passes.
public enum HangGuard {
    /// How long anything may take before it counts as hung.
    public static let timeout: Duration = .seconds(120)
    /// `timeout` for `DispatchTime` arithmetic, e.g. `.now() + HangGuard.seconds`.
    public static let seconds: Double = 120

    /// Thrown after the issue is recorded, to end the test.
    public struct Hung: Error, CustomStringConvertible {
        public let description: String
    }
}

/// Runs `operation` and returns its result. If it hasn't finished after `timeout`, records an issue naming `what`
/// hung, cancels it and throws `HangGuard.Hung` without waiting for it: a hang that ignores cancellation still
/// fails the test instead of hanging the suite.
@discardableResult
public func withHangGuard<T: Sendable>(
    _ what: String, timeout: Duration = HangGuard.timeout, sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = Race<T>()
    let work = Task { try await operation() }
    let timer = Task {
        try await Task.sleep(for: timeout)
        race.finish(.failure(Race<T>.TimedOut()))
    }
    Task {
        race.finish(await work.result)
        timer.cancel()
    }
    let result = await withTaskCancellationHandler {
        await race.result()
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
    if case .failure(let error) = result, error is Race<T>.TimedOut {
        work.cancel()
        Issue.record("\(what) didn't finish within \(timeout)", sourceLocation: sourceLocation)
        throw HangGuard.Hung(description: "\(what) hung")
    }
    if case .failure = result { work.cancel(); timer.cancel() }
    return try result.get()
}

/// The first of the operation, the timer and cancellation to finish.
private final class Race<T: Sendable>: Sendable {
    struct TimedOut: Error {}
    private struct State {
        var result: Result<T, any Error>?
        var waiter: CheckedContinuation<Result<T, any Error>, Never>?
    }

    private let state = Mutex(State())

    func finish(_ result: Result<T, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Result<T, any Error>, Never>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: result)
    }

    func result() async -> Result<T, any Error> {
        await withCheckedContinuation { continuation in
            let result = state.withLock { state -> Result<T, any Error>? in
                if state.result == nil { state.waiter = continuation }
                return state.result
            }
            if let result { continuation.resume(returning: result) }
        }
    }
}

/// Waits until `condition` holds, checking it again every few milliseconds. Records an issue naming `what` and
/// throws `HangGuard.Hung` only if it still doesn't hold after `timeout`. Use it to wait for something to happen,
/// never to show that something doesn't happen: a short wait proves nothing under load.
public func eventually(
    _ what: String, timeout: Duration = HangGuard.timeout, sourceLocation: SourceLocation = #_sourceLocation,
    isolation: isolated (any Actor)? = #isolation, _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("\(what) didn't happen within \(timeout)", sourceLocation: sourceLocation)
            throw HangGuard.Hung(description: "\(what) didn't happen")
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A barrier a test opens. `wait()` suspends until `open()` is called, or returns at once if it already was; any
/// number of tasks may wait. Hold a fake agent at an explicit point with it, and let the agent tell the test it got
/// there with another gate. Waiting ends with `CancellationError` when the waiting task is cancelled, so
/// `withHangGuard` can end a wait that never opens.
public final class TestGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public var isOpen: Bool { state.withLock { $0.isOpen } }

    /// Releases every waiter, now and later. Opening twice does nothing more.
    public func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    public func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let proceed: Result<Void, any Error>? = state.withLock { state in
                    if state.isOpen { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let proceed { continuation.resume(with: proceed) }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    /// `wait()` with a hang guard: fails the test if the gate isn't opened within `timeout`.
    public func wait(
        for what: String, timeout: Duration = HangGuard.timeout, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await withHangGuard(what, timeout: timeout, sourceLocation: sourceLocation) { try await self.wait() }
    }
}
