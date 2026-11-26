import AgentOSCore
import Foundation

/// An allowlist of agent-work settings, deliberately excluding account and tracker configuration.
struct RepositoryRunPolicy: Encodable {
    struct Review: Encodable {
        let level: ReviewLevel
        let areas: [String: ReviewLevel]
        let maxRounds: Int
    }

    struct Limits: Encodable {
        let maxAttempts: Int
        let maxReworks: Int
        let maxAgentRuns: Int
        let maxParallelAgents: Int
        let landingBatchSize: Int
        let agentTimeouts: [String: Int]
    }

    let review: Review
    let guesswork: Guesswork
    let limits: Limits
    let deniedTools: [String]
    let protectedPaths: [String]
    let leafTests: RepoConfig.LeafTests?
    let build: RepoConfig.Build?
    let test: RepoConfig.Test
    let checks: [RepoConfig.NamedCheck]

    init(policy: EffectivePolicy, config: RepoConfig) {
        let work = policy.policy
        review = Review(level: work.review.level, areas: work.review.areas, maxRounds: work.review.maxRounds)
        guesswork = work.guesswork
        limits = Limits(
            maxAttempts: work.maxAttempts, maxReworks: work.maxReworks, maxAgentRuns: work.maxAgentRuns,
            maxParallelAgents: policy.maxParallelAgents, landingBatchSize: work.landingBatchSize,
            agentTimeouts: policy.agentTimeouts)
        deniedTools = policy.deniedTools
        protectedPaths = policy.protectedPaths
        leafTests = config.leafTests
        build = config.build.map {
            RepoConfig.Build(prepare: $0.prepare.map(Self.redact), command: $0.command.map(Self.redact))
        }
        test = RepoConfig.Test(command: Self.redact(config.test.command), only: config.test.only.map(Self.redact))
        checks = (config.checks ?? []).map {
            RepoConfig.NamedCheck(name: Self.redact($0.name), command: Self.redact($0.command))
        }
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    private static func redact(_ command: String) -> String {
        // Shell values can be quoted and contain spaces or escaped quotes. Keep their option/variable names,
        // but never put credential values or URL userinfo in the ledger.
        let value = #"(?:'[^']*'|"(?:\\.|[^"\\])*"|\\.|[^\s;&|<>()'"\\])+"#
        let credential = #"(?:[a-z0-9_-]*(?:token|password|passwd|secret|credential|api[_-]?key|access[_-]?key|private[_-]?key|authorization|username|account)[a-z0-9_-]*|auth|user|login)"#
        let replacements = [
            (#"(?i)(\b(?:authorization|proxy-authorization)\s*[:=]\s*["']?(?:bearer|basic|token)\s+)[^\s"';&|]+"#, "$1[REDACTED]"),
            (#"(?i)([a-z][a-z0-9+.-]*://)[^\s/@]+@"#, "$1[REDACTED]@"),
            (#"(?i)((?<![a-z0-9_-])"# + credential + #"\s*=\s*)"# + value, "$1[REDACTED]"),
            (#"(?i)((?<!\S)--?"# + credential + #"(?:=|\s+))"# + value, "$1[REDACTED]"),
            (#"(?i)((?<!\S)-u\s+)"# + value, "$1[REDACTED]"),
            (#"(?i)([?&]"# + credential + #"=)[^&#\s"']+"#, "$1[REDACTED]"),
            (#"\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+)\b"#, "[REDACTED]")
        ]
        return replacements.reduce(command) { text, replacement in
            text.replacingOccurrences(
                of: replacement.0, with: replacement.1, options: .regularExpression)
        }
    }
}
