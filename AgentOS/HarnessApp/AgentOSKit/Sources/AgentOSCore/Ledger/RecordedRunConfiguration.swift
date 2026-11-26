/// The starting configuration retained for a run, independently of its later settings or outcome.
public struct RecordedRunConfiguration: Sendable, Equatable {
    public let fingerprint: String
    public let parts: RunConfigurationParts

    public init(fingerprint: String, parts: RunConfigurationParts) {
        self.fingerprint = fingerprint
        self.parts = parts
    }
}
