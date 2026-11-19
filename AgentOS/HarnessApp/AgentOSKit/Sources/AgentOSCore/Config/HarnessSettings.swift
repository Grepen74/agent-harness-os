import Foundation

/// The harness's own settings for every repo on this Mac: the outer limits (doc 04 §8). A repo's config may
/// choose within them or make them stricter, never looser. Set in the app's Settings window.
public struct HarnessSettings: Codable, Sendable, Equatable {
    /// Retained for decoding older settings; requirement branches now determine the landing target.
    public var landingBranch = "agentos/main"
    public var maxAttempts = 3
    public var maxReworks = 3
    /// Test-author and implementer runs per ticket before a person must look.
    public var maxAgentRuns = 12
    public var maxParallelAgents = 2
    public var avoidOverlappingWork = true
    public var pullRequests = false
    /// The signals people may use at all (doc 05 §3).
    public var offeredSignals: Set<HarnessCommand> = Set(HarnessCommand.allCases)
    /// The signals there were when these settings were saved, so a newer signal is offered rather than looking
    /// as if it had been switched off.
    public var knownSignals: Set<HarnessCommand> = Set(HarnessCommand.allCases)
    /// Models a repo may choose for its agents. Empty: only the agent CLI's default model.
    public var offeredModels: [String] = []
    /// The model per role when the repo doesn't choose one (nil: the agent CLI's default).
    public var models = AgentModels()
    /// The reasoning effort per role when the repo doesn't choose one (nil: the agent CLI's default).
    public var efforts = AgentEfforts()
    /// The highest effort a repo may choose for a role (or the role's effort above, if that is higher).
    public var maxEffort = ReasoningEffort.high
    /// Seconds each agent may run before it is stopped, per agent ("decomposer", "testAuthor", "implementer",
    /// "reviewer", "diagnoser"), when the repo doesn't choose. Agents missing here get the built-in default.
    public var agentTimeouts = EffectivePolicy.defaultAgentTimeouts
    /// The longest timeout a repo may choose for any agent, and the longest you may set here.
    public var maxAgentTimeout = EffectivePolicy.defaultMaxAgentTimeout
    /// The models and efforts the agent CLI offered when last detected (nil: never detected).
    public var modelCatalog: ModelCatalog?
    public var review = ReviewSettings()
    /// How much agents may guess before asking (a repo may only choose a stricter level).
    public var guesswork = Guesswork.assumeAndReport
    /// The `gh` account the harness uses for GitHub Issues, when several are logged in (nil: the active one).
    public var githubAccount: String?

    /// Agents may never publish; these tools are always denied and paths protected. Agents work in worktrees
    /// that share the repo's `.git`: fetches, stashes, remotes and config would change your repo, and `gh` could push.
    public static let deniedTools = ["git push", "git fetch", "git pull", "git remote", "git config", "git stash", "gh",
                                     "network installs"]
    public static let protectedPaths = ["AGENTS.md", "CONTRIBUTING*", "CODEOWNERS", ".github/copilot-instructions.md", ".agentos/"]
    /// The only agent provider so far.
    public static let agentProvider = "Copilot CLI"

    public init() {}

    /// Settings saved by an older version lack the newer keys; those get their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HarnessSettings()
        landingBranch = try container.decodeIfPresent(String.self, forKey: .landingBranch) ?? defaults.landingBranch
        maxAttempts = try container.decodeIfPresent(Int.self, forKey: .maxAttempts) ?? defaults.maxAttempts
        maxReworks = try container.decodeIfPresent(Int.self, forKey: .maxReworks) ?? defaults.maxReworks
        maxAgentRuns = try container.decodeIfPresent(Int.self, forKey: .maxAgentRuns) ?? defaults.maxAgentRuns
        maxParallelAgents = try container.decodeIfPresent(Int.self, forKey: .maxParallelAgents) ?? defaults.maxParallelAgents
        avoidOverlappingWork = try container.decodeIfPresent(Bool.self, forKey: .avoidOverlappingWork)
            ?? defaults.avoidOverlappingWork
        pullRequests = try container.decodeIfPresent(Bool.self, forKey: .pullRequests) ?? false
        let known = try container.decodeIfPresent(Set<HarnessCommand>.self, forKey: .knownSignals)
            ?? [.preview, .breakdown, .build, .go, .retry, .retest]
        let offered = try container.decodeIfPresent(Set<HarnessCommand>.self, forKey: .offeredSignals) ?? defaults.offeredSignals
        offeredSignals = offered.union(Set(HarnessCommand.allCases).subtracting(known))
        offeredModels = try container.decodeIfPresent([String].self, forKey: .offeredModels) ?? defaults.offeredModels
        models = try container.decodeIfPresent(AgentModels.self, forKey: .models) ?? defaults.models
        efforts = try container.decodeIfPresent(AgentEfforts.self, forKey: .efforts) ?? defaults.efforts
        maxEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .maxEffort) ?? defaults.maxEffort
        agentTimeouts = defaults.agentTimeouts.merging(
            try container.decodeIfPresent([String: Int].self, forKey: .agentTimeouts) ?? [:]) { _, saved in saved }
        maxAgentTimeout = try container.decodeIfPresent(Int.self, forKey: .maxAgentTimeout) ?? defaults.maxAgentTimeout
        modelCatalog = try container.decodeIfPresent(ModelCatalog.self, forKey: .modelCatalog)
        review = try container.decodeIfPresent(ReviewSettings.self, forKey: .review) ?? defaults.review
        guesswork = try container.decodeIfPresent(Guesswork.self, forKey: .guesswork) ?? defaults.guesswork
        githubAccount = try container.decodeIfPresent(String.self, forKey: .githubAccount)
    }
}

/// One effective value and where it comes from, for the settings pane.
public struct EffectiveSetting: Sendable, Identifiable, Equatable {
    public enum Source: String, Sendable { case harness, repo }

    public let name: String
    public let value: String
    public let source: Source
    /// E.g. why the repo's value wasn't used.
    public let note: String?
    public let overrides: [RepoConfigOverride]

    public var overrideActionTitle: String? {
        overrides.isEmpty ? nil : "Override in repo config…"
    }

    init(name: String, value: String, source: Source, note: String?, overrides: [RepoConfigOverride] = []) {
        self.name = name
        self.value = value
        self.source = source
        self.note = note
        self.overrides = overrides
    }

    public var id: String { name }
}

/// What actually applies to one repo: the harness's limits combined with the repo config.
public struct EffectivePolicy: Sendable, Equatable {
    public var githubAccount: String? { overrideHarness.githubAccount }
    public var settings: [EffectiveSetting] = []
    /// For the reconciler.
    public var policy = Policy()
    public var landingBranch: String
    public var maxParallelAgents: Int {
        get { policy.maxParallelAgents }
        set { policy.maxParallelAgents = newValue }
    }
    public var deniedTools: [String]
    public var protectedPaths: [String]
    /// The model per agent role.
    public var agentModels = AgentModels()
    /// The reasoning effort per agent role.
    public var agentEfforts = AgentEfforts()
    /// Seconds each agent may run before it is stopped, per agent ("testAuthor", "reviewer", …).
    public var agentTimeouts = Self.defaultAgentTimeouts
    public static let defaultAgentTimeouts = ["decomposer": 1200, "testAuthor": 1200, "implementer": 1200,
                                              "reviewer": 1200, "diagnoser": 600]
    /// The built-in outer limit for any agent's timeout; harness settings may change it within `timeoutRange`.
    public static let defaultMaxAgentTimeout = 3600
    /// Any timeout, and the outer limit itself, stays within this range of seconds.
    public static let timeoutRange = 60...14_400
    /// The repo config tried to loosen a limit or set something invalid; the harness's value applies instead.
    public var problems: [Finding] = []
    var overrideHarness = HarnessSettings()
    var repoDisabledTokens: [String] = []

    /// - `defaultBranch`: the repo's main branch. Landing there directly would skip your review.
    public static func resolve(harness: HarnessSettings, repo: RepoConfig?, defaultBranch: String?) -> EffectivePolicy {
        var result = EffectivePolicy(landingBranch: "agentos/<ticket key>", deniedTools: HarnessSettings.deniedTools,
                                     protectedPaths: HarnessSettings.protectedPaths)
        result.maxParallelAgents = harness.maxParallelAgents
        result.overrideHarness = harness
        result.repoDisabledTokens = repo?.signals?.disable ?? []

        func refuse(_ title: String, _ detail: String) {
            result.problems.append(Finding(check: "config.policy", severity: .blocker, title: title, detail: detail,
                                           suggestion: "Change \(RepoConfig.path); the repo may only make limits stricter."))
        }

        if repo?.landing?.branch != nil {
            result.problems.append(Finding(
                check: "config.landing", severity: .warning, title: "landing.branch is ignored",
                detail: "The configured value has no effect. Each requirement uses agentos/<ticket key>.",
                suggestion: "Remove landing.branch from \(RepoConfig.path)."))
        }
        result.settings.append(EffectiveSetting(name: "Landing branch", value: "agentos/<ticket key>",
                                                source: .harness, note: nil))
        result.policy.pullRequests = harness.pullRequests && repo?.pullRequests != false
        let refusedPublishing = repo?.pullRequests == true && !harness.pullRequests
        if refusedPublishing {
            refuse("Repo config enables pull requests",
                   "pullRequests may only be enabled when Push / open pull requests is on in harness settings.")
        }
        result.settings.append(EffectiveSetting(
            name: "Push / open pull requests", value: result.policy.pullRequests ? "On" : "Off",
            source: repo?.pullRequests != nil && !refusedPublishing ? .repo : .harness,
            note: refusedPublishing ? "repo asked for On: refused" : nil))

        // Limits: lower is fine, higher is refused.
        func limit(_ name: String, key: String, harness: Int, repo: Int?) -> Int {
            let range = RepoOverrideDefinitions.limitRange(maximum: harness)
            let choices = range.map { $0.map { value in
                RepoConfigOverride(value: String(value), json: "{ \"limits\": { \"\(key)\": \(value) } }")
            } } ?? []
            func append(_ value: Int, source: EffectiveSetting.Source, note: String? = nil) {
                result.settings.append(EffectiveSetting(name: name, value: "\(value)", source: source,
                                                        note: note, overrides: choices))
            }
            guard let repo else {
                append(harness, source: .harness)
                return harness
            }
            if repo > harness {
                refuse("Repo config raises \(name.lowercased()) from \(harness) to \(repo)", "The harness allows at most \(harness).")
                append(harness, source: .harness, note: "repo asked for \(repo): refused")
                return harness
            }
            if range?.contains(repo) != true {
                refuse("Repo config sets \(name.lowercased()) to \(repo)", "It must be at least 1.")
                append(harness, source: .harness, note: "repo asked for \(repo): invalid")
                return harness
            }
            append(repo, source: .repo)
            return repo
        }
        result.policy.maxAttempts = limit("Max attempts per leaf", key: "maxAttempts",
                                          harness: harness.maxAttempts, repo: repo?.limits?.maxAttempts)
        result.policy.maxReworks = limit("Max reworks per leaf", key: "maxReworks",
                                         harness: harness.maxReworks, repo: repo?.limits?.maxReworks)
        result.policy.maxAgentRuns = limit("Max agent runs per ticket", key: "maxAgentRuns",
                                           harness: harness.maxAgentRuns, repo: repo?.limits?.maxAgentRuns)
        result.maxParallelAgents = limit("Max parallel agents", key: "maxParallelAgents",
                                          harness: harness.maxParallelAgents, repo: repo?.limits?.maxParallelAgents)

        let overlapFromRepo = repo?.limits?.avoidOverlappingWork == true
        let overlapRefused = harness.avoidOverlappingWork && repo?.limits?.avoidOverlappingWork == false
        result.policy.avoidOverlappingWork = harness.avoidOverlappingWork || overlapFromRepo
        if overlapRefused {
            refuse("Repo config turns off overlap avoidance",
                   "The harness requires avoiding overlapping work. Remove limits.avoidOverlappingWork or set it to true.")
        }
        result.settings.append(EffectiveSetting(
            name: "Avoid building overlapping work at the same time",
            value: result.policy.avoidOverlappingWork ? "On" : "Off",
            source: overlapFromRepo ? .repo : .harness,
            note: overlapRefused ? "repo asked for false: refused" : nil))

        // Guesswork: the repo may only choose a stricter level.
        var guesswork = harness.guesswork
        var guessworkNote: String?
        var guessworkFromRepo = false
        let guessworkChoices = RepoOverrideDefinitions.guessworkChoices(maximum: harness.guesswork)
        if let wanted = repo?.agents?.guesswork {
            let levels = Guesswork.allCases.map(\.rawValue).joined(separator: ", ")
            if let level = Guesswork(rawValue: wanted), guessworkChoices.contains(level) {
                guesswork = level
                guessworkFromRepo = true
            } else if let level = Guesswork(rawValue: wanted) {
                refuse("Repo config loosens guesswork from \(harness.guesswork.rawValue) to \(level.rawValue)",
                       "The harness allows at most \(harness.guesswork.rawValue).")
                guessworkNote = "repo asked for \(wanted): refused"
            } else {
                refuse("Repo config has an unknown guesswork level: \(wanted)", "Known levels: \(levels).")
                guessworkNote = "repo asked for \(wanted): invalid"
            }
        }
        result.policy.guesswork = guesswork

        // Agent timeouts: the harness's own, then a repo whose work takes longer may raise them, up to the harness's limit.
        let maxAgentTimeout = min(max(harness.maxAgentTimeout, timeoutRange.lowerBound), timeoutRange.upperBound)
        for (agent, seconds) in harness.agentTimeouts where defaultAgentTimeouts[agent] != nil {
            result.agentTimeouts[agent] = min(max(seconds, timeoutRange.lowerBound), maxAgentTimeout)
        }
        var timeoutsFromRepo = false
        for (agent, seconds) in (repo?.agents?.timeouts ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard defaultAgentTimeouts[agent] != nil else {
                refuse("Repo config sets a timeout for an unknown agent: \(agent)",
                       "Known agents: \(defaultAgentTimeouts.keys.sorted().joined(separator: ", ")).")
                continue
            }
            guard (timeoutRange.lowerBound...maxAgentTimeout).contains(seconds) else {
                refuse("Repo config sets the \(agent) timeout to \(seconds) seconds",
                       "It must be \(timeoutRange.lowerBound) to \(maxAgentTimeout) seconds.")
                continue
            }
            result.agentTimeouts[agent] = seconds
            timeoutsFromRepo = true
        }
        result.settings.append(EffectiveSetting(
            name: "Agent timeouts",
            value: result.agentTimeouts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) s" }.joined(separator: ", "),
            source: timeoutsFromRepo ? .repo : .harness, note: nil))
        result.settings.append(EffectiveSetting(
            name: "Guesswork", value: "\(guesswork.title) (`\(guesswork.rawValue)`)",
            source: guessworkFromRepo ? .repo : .harness, note: guessworkNote,
            overrides: guessworkChoices.map {
                RepoConfigOverride(value: $0.rawValue, json: "{ \"agents\": { \"guesswork\": \"\($0.rawValue)\" } }")
            }))

        // Signals: the repo may only switch off what the harness offers.
        var signals = harness.offeredSignals
        var unknown: [String] = []
        for name in repo?.signals?.disable ?? [] {
            if let command = RepoOverrideDefinitions.signal(for: name) { signals.remove(command) } else { unknown.append(name) }
        }
        if !unknown.isEmpty {
            result.problems.append(Finding(
                check: "config.policy", severity: .warning, title: "Repo config disables unknown signals: \(unknown.joined(separator: ", "))",
                detail: "Known signals: \(RepoOverrideDefinitions.knownSignalTokens.joined(separator: ", "))."))
        }
        result.policy.allowedSignals = signals
        let signalNames = HarnessCommand.allCases.filter(signals.contains).map(\.rawValue).joined(separator: ", ")
        result.settings.append(EffectiveSetting(name: "Signals", value: signalNames.isEmpty ? "none" : signalNames,
                                                source: repo?.signals != nil && unknown.isEmpty ? .repo
                                                    : signals == harness.offeredSignals ? .harness : .repo, note: nil))

        // Lists the repo may only extend.
        func extend(_ name: String, _ base: [String], with extra: [String]?) -> [String] {
            let added = (extra ?? []).filter { !base.contains($0) }
            result.settings.append(EffectiveSetting(name: name, value: (base + added).joined(separator: ", "),
                                                    source: added.isEmpty ? .harness : .repo,
                                                    note: added.isEmpty ? nil : "repo added \(added.joined(separator: ", "))"))
            return base + added
        }
        result.deniedTools = extend("Denied agent tools", HarnessSettings.deniedTools, with: repo?.agents?.deny)
        result.protectedPaths = extend("Protected paths", HarnessSettings.protectedPaths, with: repo?.protectedPaths)
        result.policy.protectedPaths = result.protectedPaths

        let catalog = harness.modelCatalog
        result.settings.append(EffectiveSetting(
            name: "Models detected", value: catalog?.detectedDescription ?? "never", source: .harness,
            note: catalog == nil ? "Settings › Detect models lists your account's models and their efforts" : nil))

        // Agents: the harness's model per role, unless the repo picks another one the harness offers.
        for role in AgentModels.roles {
            var model = harness.models[role]
            var source = EffectiveSetting.Source.harness
            var note: String?
            if let wanted = repo?.agents?.models?[role] {
                if RepoOverrideDefinitions.modelChoices(for: role, harness: harness).contains(wanted) {
                    model = wanted
                    source = .repo
                } else {
                    let offered = harness.offeredModels.isEmpty ? "none (only the default model)" : harness.offeredModels.joined(separator: ", ")
                    refuse("Repo config picks model \(wanted) for \(role.job.lowercased())",
                           "The harness doesn't offer it. Offered: \(offered).")
                    note = "repo asked for \(wanted): not offered"
                }
            }
            result.agentModels[role] = model
            if let catalog, let model, catalog.model(model) == nil {
                note = [note, "not among the models detected \(catalog.detectedDescription): possibly unavailable"]
                    .compactMap { $0 }.joined(separator: "; ")
            }
            result.settings.append(EffectiveSetting(
                name: "\(role.job) agent", value: "\(HarnessSettings.agentProvider) · \(model ?? "default model")",
                source: source, note: note))
        }

        // Reasoning effort: the harness's per role, unless the repo picks another one up to the harness's cap.
        for role in AgentEfforts.roles {
            var effort = harness.efforts[role]
            var source = EffectiveSetting.Source.harness
            var note: String?
            let choices = RepoOverrideDefinitions.effortChoices(for: role, harness: harness)
            if let wanted = repo?.agents?.efforts?[role] {
                if let level = ReasoningEffort(rawValue: wanted), choices.contains(level) {
                    effort = level
                    source = .repo
                } else if let level = ReasoningEffort(rawValue: wanted) {
                    refuse("Repo config raises \(role.job.lowercased()) reasoning effort to \(level.rawValue)",
                           "The harness allows at most \(choices.last?.rawValue ?? "none").")
                    note = "repo asked for \(wanted): refused"
                } else {
                    refuse("Repo config has an unknown reasoning effort for \(role.job.lowercased()): \(wanted)",
                           "Known levels: \(ReasoningEffort.allCases.map(\.rawValue).joined(separator: ", ")).")
                    note = "repo asked for \(wanted): invalid"
                }
            }
            result.agentEfforts[role] = effort
            if let catalog, let effort, catalog.supports(effort, model: result.agentModels[role]) == false {
                let model = result.agentModels[role] ?? catalog.defaultModel ?? "the default model"
                note = [note, "\(model) doesn't support \(effort.rawValue): runs with the CLI's default effort"]
                    .compactMap { $0 }.joined(separator: "; ")
            }
            result.settings.append(EffectiveSetting(
                name: "\(role.job) reasoning effort", value: effort?.rawValue ?? "default",
                source: source, note: note,
                overrides: choices.map {
                    RepoConfigOverride(value: $0.rawValue,
                                       json: "{ \"agents\": { \"efforts\": { \"\(role.rawValue)\": \"\($0.rawValue)\" } } }")
                }))
        }
        var review = ReviewPolicy()
        review.level = harness.review.level
        review.baseBranch = result.landingBranch
        review.instructions = repo?.review?.instructions
        var levelSource = EffectiveSetting.Source.harness
        var levelNote: String?
        if let wanted = repo?.review?.level {
            if let level = ReviewLevel(rawValue: wanted), level >= harness.review.level {
                review.level = level
                levelSource = .repo
            } else {
                refuse("Repo config weakens or invalidates review: \(wanted)",
                       "The harness requires at least \(harness.review.level.rawValue) review.")
                levelNote = "repo asked for \(wanted): refused"
            }
        }
        for (area, wanted) in repo?.review?.areas ?? [:] {
            if let level = ReviewLevel(rawValue: wanted), level >= review.level {
                review.areas[area] = level
            } else {
                refuse("Repo config weakens or invalidates review for \(area): \(wanted)",
                       "Review must be at least \(review.level.rawValue).")
            }
        }
        if let rounds = repo?.review?.maxRounds {
            if rounds > 0 { review.maxRounds = rounds }
            else { refuse("Invalid review maxRounds: \(rounds)", "Use at least one review round.") }
        }
        review.reviewer = harness.review.reviewer
        var reviewerSource = EffectiveSetting.Source.harness
        var reviewerNote: String?
        if let wanted = repo?.review?.model {
            if harness.review.offeredModels.contains(wanted) {
                review.reviewer = ReviewerSelection(type: "specific", model: wanted)
                reviewerSource = .repo
            } else {
                refuse("Repo config picks unoffered reviewer \(wanted)",
                       "Offered reviewer models: \(harness.review.offeredModels.joined(separator: ", ")).")
                reviewerNote = "repo asked for \(wanted): not offered"
            }
        }
        let selection = review.reviewer
        if selection.type == "default" {
            // Only models you listed: which ones exist depends on your Copilot account and changes over time.
            let implementer = result.agentModels[.implementer]
            review.reviewer.model = harness.review.offeredModels.first { $0 != implementer }
            review.reviewer.command = nil
            if review.reviewer.model == nil, reviewerNote == nil {
                reviewerNote = "the agent CLI's default model; list offered reviewer models to review with a "
                    + "different model from the implementer's"
            }
        } else if selection.type != "specific"
                    || ((selection.model?.isEmpty != false) == (selection.command?.isEmpty != false)) {
            refuse("Invalid reviewer selection", "Choose default, or specific with exactly one model or command.")
        }
        if review.reviewer.command == nil, let chosen = review.reviewer.model {
            let implementer = result.agentModels[.implementer]
            review.reviewerFallbacks = harness.review.offeredModels.filter { $0 != chosen && $0 != implementer } + [nil]
        }
        result.policy.review = review
        result.settings.append(EffectiveSetting(name: "Review level", value: review.level.rawValue,
                                                source: levelSource, note: levelNote))
        result.settings.append(EffectiveSetting(name: "Reviewer",
                                                value: review.reviewer.command ?? review.reviewer.model ?? "CLI default model",
                                                source: reviewerSource, note: reviewerNote))
        return result
    }

    static func isLocalBranchName(_ name: String) -> Bool {
        // `agentos/leaf/…` holds the leaves' branches, so `agentos` itself can't be a branch too.
        guard name != "agentos", !name.hasPrefix("agentos/leaf/") else { return false }
        return !name.isEmpty && !name.hasPrefix("origin/") && !name.hasPrefix("refs/") && !name.hasPrefix("-") && !name.hasSuffix("/")
            && !name.contains("..") && !name.contains(where: { $0.isWhitespace || "~^:?*[\\".contains($0) })
    }
}
