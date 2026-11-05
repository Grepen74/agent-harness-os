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

    /// Not settings: the harness never pushes, and these are always denied and protected.
    public static let deniedTools = ["git push", "network installs"]
    public static let protectedPaths = ["AGENTS.md", "CONTRIBUTING*", "CODEOWNERS", ".github/copilot-instructions.md", ".agentos/"]

    public init() {}
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
    public var maxParallelAgents: Int
    public var deniedTools: [String]
    public var protectedPaths: [String]
    /// The repo config tried to loosen a limit or set something invalid; the harness's value applies instead.
    public var problems: [Finding] = []

    /// - `defaultBranch`: the repo's main branch. Landing there directly would skip your review.
    public static func resolve(harness: HarnessSettings, repo: RepoConfig?, defaultBranch: String?) -> EffectivePolicy {
        var result = EffectivePolicy(landingBranch: harness.landingBranch, maxParallelAgents: harness.maxParallelAgents,
                                     deniedTools: HarnessSettings.deniedTools, protectedPaths: HarnessSettings.protectedPaths)

        func refuse(_ title: String, _ detail: String) {
            result.problems.append(Finding(check: "config.policy", severity: .blocker, title: title, detail: detail,
                                           suggestion: "Change \(RepoConfig.path); the repo may only make limits stricter."))
        }

        // Landing branch: any other local branch name, but never the default branch itself.
        var landingNote: String?
        if let wanted = repo?.landing?.branch {
            if wanted == defaultBranch {
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

        // Signals: the repo may only switch off what the harness offers.
        var signals = harness.offeredSignals
        var unknown: [String] = []
        for name in repo?.signals?.disable ?? [] {
            let raw = name.hasPrefix("harness:") ? String(name.dropFirst("harness:".count)) : name
            if let command = HarnessCommand(rawValue: raw) { signals.remove(command) } else { unknown.append(name) }
        }
        if !unknown.isEmpty {
            result.problems.append(Finding(
                check: "config.policy", severity: .warning, title: "Repo config disables unknown signals: \(unknown.joined(separator: ", "))",
                detail: "Known signals: \(HarnessCommand.allCases.map(\.rawValue).joined(separator: ", "))."))
        }
        result.policy.allowedSignals = signals
        let signalNames = HarnessCommand.allCases.filter(signals.contains).map(\.rawValue).joined(separator: ", ")
        result.settings.append(EffectiveSetting(name: "Signals", value: signalNames.isEmpty ? "none" : signalNames,
                                                source: signals == harness.offeredSignals ? .harness : .repo, note: nil))

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
        return result
    }

    static func isLocalBranchName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("origin/") && !name.hasPrefix("refs/") && !name.hasPrefix("-") && !name.hasSuffix("/")
            && !name.contains("..") && !name.contains(where: { $0.isWhitespace || "~^:?*[\\".contains($0) })
    }
}
