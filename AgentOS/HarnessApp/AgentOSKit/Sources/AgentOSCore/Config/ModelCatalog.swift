import Foundation

/// The models the agent CLI offered when last asked (Settings › Detect models), and the reasoning efforts each
/// supports. Only a guide: the account's models can change, so runs still fall back when a model or effort isn't
/// available.
public struct ModelCatalog: Codable, Sendable, Equatable {
    public struct Model: Codable, Sendable, Equatable, Identifiable {
        /// As `copilot --model` takes it.
        public var id: String
        public var name: String
        /// E.g. "Versatile · Medium cost".
        public var details: String?
        /// E.g. "1x": what a request costs against the account's allowance.
        public var usage: String?
        /// False when the account has the model but it isn't switched on.
        public var enabled: Bool
        /// The levels the model takes. Empty: it has no reasoning effort setting. nil: the CLI didn't say.
        public var efforts: [ReasoningEffort]?
        /// What the model uses when no effort is given.
        public var defaultEffort: ReasoningEffort?

        public init(id: String, name: String, details: String? = nil, usage: String? = nil, enabled: Bool = true,
                    efforts: [ReasoningEffort]? = nil, defaultEffort: ReasoningEffort? = nil) {
            self.id = id
            self.name = name
            self.details = details
            self.usage = usage
            self.enabled = enabled
            self.efforts = efforts
            self.defaultEffort = defaultEffort
        }
    }

    public var models: [Model]
    public var detectedAt: Date
    /// The CLI's default model when detected, outside any repository (a repository default may differ).
    public var defaultModel: String?
    public var cliVersion: String?

    public init(models: [Model], detectedAt: Date, defaultModel: String? = nil, cliVersion: String? = nil) {
        self.models = models
        self.detectedAt = detectedAt
        self.defaultModel = defaultModel
        self.cliVersion = cliVersion
    }

    /// `id`, or the CLI's default model for nil.
    public func model(_ id: String?) -> Model? {
        guard let id = id ?? defaultModel else { return nil }
        return models.first { $0.id == id }
    }

    /// The efforts `model` (nil: the CLI's default) supports, or nil when that isn't known.
    public func efforts(for model: String?) -> [ReasoningEffort]? {
        self.model(model)?.efforts
    }

    /// Whether `model` (nil: the CLI's default) takes `effort`; nil when that isn't known.
    public func supports(_ effort: ReasoningEffort, model: String?) -> Bool? {
        efforts(for: model).map { $0.contains(effort) }
    }

    /// The models in `offered` that weren't detected, so may no longer be available.
    public func missing(from offered: [String]) -> [String] {
        offered.filter { id in !models.contains { $0.id == id } }
    }

    /// `offered` plus `chosen`, keeping the order and without duplicates.
    public static func adding(_ chosen: [String], to offered: [String]) -> [String] {
        var seen = Set(offered)
        return offered + chosen.filter { seen.insert($0).inserted }
    }

    /// How it reads in the settings: "15 Nov 2026 at 21:07 (CLI 1.0.112)".
    public var detectedDescription: String {
        detectedAt.formatted(date: .abbreviated, time: .shortened) + (cliVersion.map { " (CLI \($0))" } ?? "")
    }
}
