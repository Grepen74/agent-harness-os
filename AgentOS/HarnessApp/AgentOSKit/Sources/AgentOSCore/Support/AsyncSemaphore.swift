import Foundation

/// At most `value` holders at a time; the others wait their turn, first come first served.
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(_ value: Int) { available = value }

    public func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func signal() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }

    @discardableResult
    public nonisolated func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await wait()
        do {
            let result = try await body()
            await signal()
            return result
        } catch {
            await signal()
            throw error
        }
    }
}
