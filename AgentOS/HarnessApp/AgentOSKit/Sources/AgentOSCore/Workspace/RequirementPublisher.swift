/// The harness's publishing boundary; agents never receive this capability.
public protocol RequirementPublisher: Sendable {
    func publish(requirement: NodeIdentity, branch: String, commit: String) async throws
}
