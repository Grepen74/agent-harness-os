import Foundation

/// Eligibility shared by repo config resolution and override editors.
public enum RepoOverrideDefinitions {
    public static func guessworkChoices(maximum: Guesswork) -> [Guesswork] {
        Guesswork.allCases.filter { $0 <= maximum }
    }

    public static func limitRange(maximum: Int) -> ClosedRange<Int>? {
        maximum >= 1 ? 1...maximum : nil
    }

    public static func modelChoices(for role: AgentRole, harness: HarnessSettings) -> [String] {
        guard AgentModels.roles.contains(role) else { return [] }
        var choices: [String] = []
        for identifier in [harness.models[role]].compactMap({ $0 }) + harness.offeredModels {
            if !choices.contains(identifier) { choices.append(identifier) }
        }
        return choices
    }

    public static func signalChoices(harness: HarnessSettings) -> [HarnessCommand] {
        HarnessCommand.allCases.filter(harness.offeredSignals.contains)
    }

    public static var knownSignalTokens: [String] { HarnessCommand.allCases.map(\.rawValue) }

    static func signal(for token: String) -> HarnessCommand? {
        let raw = token.hasPrefix("harness:") ? String(token.dropFirst("harness:".count)) : token
        guard knownSignalTokens.contains(raw) else { return nil }
        return HarnessCommand(rawValue: raw)
    }
}

/// A permitted config value and the complete JSON path to merge into the repo config.
public struct RepoConfigOverride: Sendable, Equatable {
    public let value: String
    public let json: String
}

public struct ModelOverride: Sendable, Equatable {
    public let actionTitle = "Override in repo config…"
    public let keyPath: String
    public let provider: String
    public let modelIdentifier: String?
    public let choices: [String]
    public let inheritanceExplanation: String?
}

public struct SignalOverride: Sendable, Equatable {
    public let actionTitle = "Override in repo config…"
    public let keyPath = "signals.disable"
    public let enabledSignals: Set<HarnessCommand>
    public let disabledTokens: [String]
    public let choices: [HarnessCommand]
}

public enum PolicyOverrideError: Error, LocalizedError {
    case modelNotOffered(role: AgentRole, identifier: String)
    case signalsNotOffered

    public var errorDescription: String? {
        switch self {
        case let .modelNotOffered(role, identifier):
            "The harness does not offer \(identifier) for the \(role.job.lowercased()) agent. Choose an offered model."
        case .signalsNotOffered:
            "Choose only signals offered by the harness."
        }
    }
}

extension EffectivePolicy {
    public func modelOverride(for role: AgentRole) -> ModelOverride? {
        guard AgentModels.roles.contains(role) else { return nil }
        return ModelOverride(
            keyPath: "agents.models.\(role.rawValue)", provider: HarnessSettings.agentProvider,
            modelIdentifier: agentModels[role],
            choices: RepoOverrideDefinitions.modelChoices(for: role, harness: overrideHarness),
            inheritanceExplanation: agentModels[role] == nil
                ? "Inherits the CLI's default model; no concrete model identifier is configured." : nil)
    }

    public var signalOverride: SignalOverride {
        SignalOverride(enabledSignals: policy.allowedSignals, disabledTokens: repoDisabledTokens,
                       choices: RepoOverrideDefinitions.signalChoices(harness: overrideHarness))
    }

    public func modelFragment(for role: AgentRole, identifier: String) throws -> String {
        guard let row = modelOverride(for: role), row.choices.contains(identifier) else {
            throw PolicyOverrideError.modelNotOffered(role: role, identifier: identifier)
        }
        return try Self.fragment(["agents": ["models": [role.rawValue: identifier]]])
    }

    public func signalsFragment(disabling signals: Set<HarnessCommand>) throws -> String {
        let row = signalOverride
        guard signals.isSubset(of: Set(row.choices)) else { throw PolicyOverrideError.signalsNotOffered }
        var tokens: [String] = []
        for token in row.disabledTokens + row.choices.filter(signals.contains).map(\.rawValue) {
            if !tokens.contains(token) { tokens.append(token) }
        }
        return try Self.fragment(["signals": ["disable": tokens]])
    }

    private static func fragment(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
