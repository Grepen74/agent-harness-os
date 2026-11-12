import Foundation

/// The harness's own settings for every repo on this Mac: the outer limits (doc 04 §8). A repo's config may
/// choose within them or make them stricter, never looser. Set in the app's Settings window.
public struct HarnessSettings: Codable, Sendable, Equatable {
    /// Proven work lands on this local branch; you review, merge and push it yourself.
    public var landingBranch = "agentos/main"
    public var maxAttempts = 3
    public var maxReworks = 3
    public var maxParallelAgents = 2
    /// The signals people may use at all (doc 05 §3).
    public var offeredSignals: Set<HarnessCommand> = Set(HarnessCommand.allCases)
    /// The signals there were when these settings were saved, so a newer signal is offered rather than looking
    /// as if it had been switched off.
    public var knownSignals: Set<HarnessCommand> = Set(HarnessCommand.allCases)
    /// Models a repo may choose for its agents. Empty: only the agent CLI's default model.
    public var offeredModels: [String] = []
    /// The model per role when the repo doesn't choose one (nil: the agent CLI's default).
    public var models = AgentModels()
    public var review = ReviewSettings()
    /// How much agents may guess before asking (a repo may only choose a stricter level).
    public var guesswork = Guesswork.assumeAndReport
    /// The `gh` account the harness uses for GitHub Issues, when several are logged in (nil: the active one).
    public var githubAccount: String?

    /// Not settings: the harness never pushes, and these are always denied and protected. Agents work in worktrees
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
        maxParallelAgents = try container.decodeIfPresent(Int.self, forKey: .maxParallelAgents) ?? defaults.maxParallelAgents
        let known = try container.decodeIfPresent(Set<HarnessCommand>.self, forKey: .knownSignals)
            ?? [.preview, .breakdown, .build, .go, .retry, .retest]
        let offered = try container.decodeIfPresent(Set<HarnessCommand>.self, forKey: .offeredSignals) ?? defaults.offeredSignals
        offeredSignals = offered.union(Set(HarnessCommand.allCases).subtracting(known))
        offeredModels = try container.decodeIfPresent([String].self, forKey: .offeredModels) ?? defaults.offeredModels
        models = try container.decodeIfPresent(AgentModels.self, forKey: .models) ?? defaults.models
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

    public var id: String { name }
}

/// What actually applies to one repo: the harness's limits combined with the repo config.
public struct EffectivePolicy: Sendable, Equatable {
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
    /// The repo config tried to loosen a limit or set something invalid; the harness's value applies instead.
    public var problems: [Finding] = []
    var overrideHarness = HarnessSettings()
    var repoDisabledTokens: [String] = []

    /// - `defaultBranch`: the repo's main branch. Landing there directly would skip your review.
    public static func resolve(harness: HarnessSettings, repo: RepoConfig?, defaultBranch: String?) -> EffectivePolicy {
        var result = EffectivePolicy(landingBranch: harness.landingBranch, deniedTools: HarnessSettings.deniedTools,
                                     protectedPaths: HarnessSettings.protectedPaths)
        result.maxParallelAgents = harness.maxParallelAgents
        result.overrideHarness = harness
        result.repoDisabledTokens = repo?.signals?.disable ?? []

        func refuse(_ title: String, _ detail: String) {
            result.problems.append(Finding(check: "config.policy", severity: .blocker, title: title, detail: detail,
                                           suggestion: "Change \(RepoConfig.path); the repo may only make limits stricter."))
        }

        // Landing branch: any other local branch name, but never the default branch itself.
        var landingNote: String?
        if let wanted = repo?.landing?.branch {
            // `origin/develop` when the clone only has the remote's default branch: its local name counts too.
            if wanted == defaultBranch || defaultBranch.map({ "origin/" + wanted == $0 }) == true {
                refuse("Repo config lands on \(wanted) directly",
                       "Proven work must land on a separate branch so a human reviews it before it reaches \(wanted).")
                landingNote = "repo asked for \(wanted): refused"
            } else if !isLocalBranchName(wanted) {
                refuse("Repo config has an invalid landing branch: \(wanted)", "It must be a local branch name.")
                landingNote = "repo asked for \(wanted): invalid"
            } else {
                result.landingBranch = wanted
            }
        }
        let landingFromRepo = result.landingBranch != harness.landingBranch
        result.settings.append(EffectiveSetting(name: "Landing branch", value: result.landingBranch,
                                                source: landingFromRepo ? .repo : .harness, note: landingNote))
        result.settings.append(EffectiveSetting(name: "Push / open pull requests", value: "Never", source: .harness, note: nil))

        // Limits: lower is fine, higher is refused.
        func limit(_ name: String, harness: Int, repo: Int?) -> Int {
            guard let repo else {
                result.settings.append(EffectiveSetting(name: name, value: "\(harness)", source: .harness, note: nil))
                return harness
            }
            if repo > harness {
                refuse("Repo config raises \(name.lowercased()) from \(harness) to \(repo)", "The harness allows at most \(harness).")
                result.settings.append(EffectiveSetting(name: name, value: "\(harness)", source: .harness,
                                                        note: "repo asked for \(repo): refused"))
                return harness
            }
            if repo < 1 {
                refuse("Repo config sets \(name.lowercased()) to \(repo)", "It must be at least 1.")
                result.settings.append(EffectiveSetting(name: name, value: "\(harness)", source: .harness,
                                                        note: "repo asked for \(repo): invalid"))
                return harness
            }
            result.settings.append(EffectiveSetting(name: name, value: "\(repo)", source: repo == harness ? .harness : .repo, note: nil))
            return repo
        }
        result.policy.maxAttempts = limit("Max attempts per leaf", harness: harness.maxAttempts, repo: repo?.limits?.maxAttempts)
        result.policy.maxReworks = limit("Max reworks per leaf", harness: harness.maxReworks, repo: repo?.limits?.maxReworks)
        result.maxParallelAgents = limit("Max parallel agents", harness: harness.maxParallelAgents, repo: repo?.limits?.maxParallelAgents)

        // Guesswork: the repo may only choose a stricter level.
        var guesswork = harness.guesswork
        var guessworkNote: String?
        if let wanted = repo?.agents?.guesswork {
            let levels = Guesswork.allCases.map(\.rawValue).joined(separator: ", ")
            if let level = Guesswork(rawValue: wanted), level <= harness.guesswork {
                guesswork = level
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
        result.settings.append(EffectiveSetting(name: "Guesswork", value: guesswork.title,
                                                source: guesswork == harness.guesswork ? .harness : .repo, note: guessworkNote))

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
            result.settings.append(EffectiveSetting(
                name: "\(role.job) agent", value: "\(HarnessSettings.agentProvider) · \(model ?? "default model")",
                source: source, note: note))
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
            review.reviewer.model = result.agentModels[.implementer] == "claude-sonnet-4.5"
                ? "gpt-5.3-codex" : "claude-sonnet-4.5"
            review.reviewer.command = nil
        } else if selection.type != "specific"
                    || ((selection.model?.isEmpty != false) == (selection.command?.isEmpty != false)) {
            refuse("Invalid reviewer selection", "Choose default, or specific with exactly one model or command.")
        }
        result.policy.review = review
        result.settings.append(EffectiveSetting(name: "Review level", value: review.level.rawValue,
                                                source: levelSource, note: levelNote))
        result.settings.append(EffectiveSetting(name: "Reviewer",
                                                value: review.reviewer.command ?? review.reviewer.model ?? "default",
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
