/// A committed acceptance-test candidate; it is not locked until `testsFixed`.
public struct AcceptanceTestRecord: Sendable {
    public let files: [String]
    public let suite: String

    public init(files: [String], suite: String) {
        self.files = files
        self.suite = suite
    }
}
