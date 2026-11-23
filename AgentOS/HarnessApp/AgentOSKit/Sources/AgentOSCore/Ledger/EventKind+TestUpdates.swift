public extension EventKind {
    /// Alternate label for callers approving tests; preserves the existing ledger encoding.
    static func testUpdatesApproved(tests: [String]) -> EventKind {
        .testUpdatesApproved(files: tests)
    }
}
