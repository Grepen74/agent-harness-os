import Foundation

/// The harness configuration at the start of a run, independent of its ticket and later fallbacks.
public struct RunConfigurationParts: Codable, Sendable, Equatable {
    public let harnessBuild: String
    public let effectivePolicyJSON: String
    public let role: AgentRole
    public let model: String
    public let effort: String
    public let agentRuntimeName: String
    public let agentRuntimeVersion: String
    public let pipelineVariant: String

    public init(harnessBuild: String, effectivePolicyJSON: String, role: AgentRole, model: String,
                effort: String, agentRuntimeName: String, agentRuntimeVersion: String,
                pipelineVariant: String) {
        self.harnessBuild = harnessBuild
        self.effectivePolicyJSON = effectivePolicyJSON
        self.role = role
        self.model = model
        self.effort = effort
        self.agentRuntimeName = agentRuntimeName
        self.agentRuntimeVersion = agentRuntimeVersion
        self.pipelineVariant = pipelineVariant
    }
}
