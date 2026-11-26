import Foundation

extension Reconciler {
    func agentConfiguration(_ run: RunID, role: AgentRole, settings: AgentRunSettings?) throws -> [EventKind] {
        guard role != .verifier else { return [] }
        let policyJSON: String
        if let supplied = effectivePolicyJSON {
            let object = try JSONSerialization.jsonObject(with: Data(supplied.utf8))
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            policyJSON = String(decoding: data, as: UTF8.self)
        } else {
            policyJSON = String(decoding: Hashing.canonicalJSON(AgentWorkPolicy(policy)), as: UTF8.self)
        }
        let parts = RunConfigurationParts(
            harnessBuild: harnessBuild, effectivePolicyJSON: policyJSON, role: role,
            model: settings?.model ?? "unknown", effort: settings?.effort ?? "unknown",
            agentRuntimeName: agentRuntimeName, agentRuntimeVersion: agentRuntimeVersion,
            pipelineVariant: "relay")
        return [.runConfigurationRecorded(run: run, fingerprint: Hashing.sha256(Hashing.canonicalJSON(parts)), parts: parts)]
    }
}

private struct AgentWorkPolicy: Encodable {
    struct Review: Encodable {
        let level: ReviewLevel
        let areas: [String: ReviewLevel]
        let maxRounds: Int
    }

    let review: Review
    let guesswork: Guesswork
    let maxAttempts: Int
    let maxReworks: Int
    let maxAgentRuns: Int
    let maxParallelAgents: Int
    let landingBatchSize: Int
    let protectedPaths: [String]

    init(_ policy: Policy) {
        review = Review(level: policy.review.level, areas: policy.review.areas, maxRounds: policy.review.maxRounds)
        guesswork = policy.guesswork
        maxAttempts = policy.maxAttempts
        maxReworks = policy.maxReworks
        maxAgentRuns = policy.maxAgentRuns
        maxParallelAgents = policy.maxParallelAgents
        landingBatchSize = policy.landingBatchSize
        protectedPaths = policy.protectedPaths
    }
}
