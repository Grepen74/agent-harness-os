import Foundation
import Synchronization

extension Reconciler {
    /// Waits until every step but `id`'s (and its landing batch's), and every preview, has finished. Used with
    /// `quietLandings`, so none starts meanwhile. Returns early when the caller is cancelled, so Stop doesn't wait
    /// for unrelated work.
    func waitForOtherWork(than id: NodeID) async {
        let own = landingBatchNodes.contains(id) ? landingBatchNodes : [id]
        let joined = own.subtracting(quietWaits)
        quietWaits.formUnion(joined)
        defer { quietWaits.subtract(joined) }
        var awaitedPreviews: Set<RunID> = []
        while !Task.isCancelled {
            if let task = tasks.first(where: { !own.contains($0.key) && !quietWaits.contains($0.key) })?.value {
                await Self.untilFinishedOrCancelled { _ = await task.value }
            } else if let preview = previewRuns.values.first(where: { !awaitedPreviews.contains($0.run) }) {
                awaitedPreviews.insert(preview.run)
                await Self.untilFinishedOrCancelled { await preview.task.value }
            } else {
                return
            }
        }
    }

    private static func untilFinishedOrCancelled(_ work: @escaping @Sendable () async -> Void) async {
        let latch = ResumeOnce()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                latch.set(continuation)
                Task {
                    await work()
                    latch.resume()
                }
            }
        } onCancel: {
            latch.resume()
        }
    }
}

/// Resumes a continuation once: whichever of finishing and cancelling comes first, even before it is set.
private final class ResumeOnce: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Void, Never>?, done: Bool)>((nil, false))

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        let done = state.withLock { state in
            if !state.done { state.continuation = continuation }
            return state.done
        }
        if done { continuation.resume() }
    }

    func resume() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.done else { return nil }
            state.done = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}
