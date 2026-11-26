import Foundation

/// The harness configuration at the start of a run, independent of its ticket and later fallbacks.
public struct RunConfigurationParts: Codable, Sendable, Equatable {
    public let harnessBuild: HarnessBuild
    public let effectivePolicyJSON: String
    public let role: AgentRole
    public let model: String
    public let effort: String
    public let agentRuntimeName: String
    public let agentRuntimeVersion: String
    public let pipelineVariant: String
    private var legacyHarnessBuild: String?

    public init(harnessBuild: HarnessBuild, effectivePolicyJSON: String, role: AgentRole, model: String,
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

    private enum CodingKeys: String, CodingKey {
        case harnessBuild, effectivePolicyJSON, role, model, effort
        case agentRuntimeName, agentRuntimeVersion, pipelineVariant
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let build: HarnessBuild
        var legacyBuild: String?
        do {
            build = try container.decode(HarnessBuild.self, forKey: .harnessBuild)
        } catch DecodingError.typeMismatch {
            let value = try container.decode(String.self, forKey: .harnessBuild)
            build = HarnessBuild(legacyValue: value)
            legacyBuild = value
        }
        self.init(
            harnessBuild: build,
            effectivePolicyJSON: try container.decode(String.self, forKey: .effectivePolicyJSON),
            role: try container.decode(AgentRole.self, forKey: .role),
            model: try container.decode(String.self, forKey: .model),
            effort: try container.decode(String.self, forKey: .effort),
            agentRuntimeName: try container.decode(String.self, forKey: .agentRuntimeName),
            agentRuntimeVersion: try container.decode(String.self, forKey: .agentRuntimeVersion),
            pipelineVariant: try container.decode(String.self, forKey: .pipelineVariant)
        )
        legacyHarnessBuild = legacyBuild
    }

    public func encode(to encoder: any Encoder) throws {
        // Hash verification must re-encode previously recorded payloads in their original shape.
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let legacyHarnessBuild {
            try container.encode(legacyHarnessBuild, forKey: .harnessBuild)
        } else {
            try container.encode(harnessBuild, forKey: .harnessBuild)
        }
        try container.encode(effectivePolicyJSON, forKey: .effectivePolicyJSON)
        try container.encode(role, forKey: .role)
        try container.encode(model, forKey: .model)
        try container.encode(effort, forKey: .effort)
        try container.encode(agentRuntimeName, forKey: .agentRuntimeName)
        try container.encode(agentRuntimeVersion, forKey: .agentRuntimeVersion)
        try container.encode(pipelineVariant, forKey: .pipelineVariant)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.harnessBuild == rhs.harnessBuild
            && lhs.effectivePolicyJSON == rhs.effectivePolicyJSON
            && lhs.role == rhs.role && lhs.model == rhs.model && lhs.effort == rhs.effort
            && lhs.agentRuntimeName == rhs.agentRuntimeName && lhs.agentRuntimeVersion == rhs.agentRuntimeVersion
            && lhs.pipelineVariant == rhs.pipelineVariant
    }
}
