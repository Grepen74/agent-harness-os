import Foundation

/// A repo's own settings for the harness: `.agentos/config.json` on the default branch (doc 01, the manifest).
/// It declares how to build and test, and may only choose within the harness's limits or make them
/// stricter (doc 04 §8). JSON so it needs no extra parser; unknown keys are reported, not ignored.
public struct RepoConfig: Codable, Sendable, Equatable {
    public struct Build: Codable, Sendable, Equatable {
        /// Run before building, e.g. `xcodegen generate`.
        public var prepare: String?
        public var command: String?

        public init(prepare: String? = nil, command: String? = nil) { self.prepare = prepare; self.command = command }
    }

    public struct Test: Codable, Sendable, Equatable {
        public var command: String
        /// Appended to `command` to run one leaf's suite; `{suite}` is replaced, e.g. `--filter {suite}`.
        public var only: String?

        public init(command: String, only: String? = nil) { self.command = command; self.only = only }
    }

    public struct NamedCheck: Codable, Sendable, Equatable {
        public var name: String
        public var command: String

        public init(name: String, command: String) { self.name = name; self.command = command }
    }

    public struct LeafTests: Codable, Sendable, Equatable {
        /// The existing test target leaves add their acceptance tests to.
        public var target: String
        public var folder: String

        public init(target: String, folder: String) { self.target = target; self.folder = folder }
    }

    public struct Landing: Codable, Sendable, Equatable {
        public var branch: String

        public init(branch: String) { self.branch = branch }
    }

    public struct Signals: Codable, Sendable, Equatable {
        /// Signals the repo switches off, e.g. `["go"]` to force a breakdown review.
        public var disable: [String]

        public init(disable: [String]) { self.disable = disable }
    }

    public struct Limits: Codable, Sendable, Equatable {
        public var maxAttempts: Int?
        public var maxReworks: Int?
        public var maxParallelAgents: Int?

        public init(maxAttempts: Int? = nil, maxReworks: Int? = nil, maxParallelAgents: Int? = nil) {
            self.maxAttempts = maxAttempts
            self.maxReworks = maxReworks
            self.maxParallelAgents = maxParallelAgents
        }
    }

    public struct Agents: Codable, Sendable, Equatable {
        /// Tools denied on top of the harness's list.
        public var deny: [String]?
        /// Models per role, chosen among the ones the harness offers.
        public var models: AgentModels?

        public init(deny: [String]? = nil, models: AgentModels? = nil) { self.deny = deny; self.models = models }
    }

    public var build: Build?
    public var test: Test
    /// More required checks after the tests, e.g. lint.
    public var checks: [NamedCheck]?
    public var leafTests: LeafTests?
    public var components: [String]?
    public var landing: Landing?
    public var signals: Signals?
    public var limits: Limits?
    public var agents: Agents?
    public var protectedPaths: [String]?

    public static let path = ".agentos/config.json"
    public static let knownKeys: Set<String> = ["build", "test", "checks", "leafTests", "components", "landing", "signals",
                                                "limits", "agents", "protectedPaths"]

    /// Every command line the config runs, in order.
    public var commands: [String] {
        [build?.prepare, build?.command, test.command].compactMap { $0 } + (checks ?? []).map(\.command)
    }

    public init(build: Build? = nil, test: Test, checks: [NamedCheck]? = nil, leafTests: LeafTests? = nil,
                components: [String]? = nil, landing: Landing? = nil, signals: Signals? = nil, limits: Limits? = nil,
                agents: Agents? = nil, protectedPaths: [String]? = nil) {
        self.build = build
        self.test = test
        self.checks = checks
        self.leafTests = leafTests
        self.components = components
        self.landing = landing
        self.signals = signals
        self.limits = limits
        self.agents = agents
        self.protectedPaths = protectedPaths
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Parses the file. Returns the config plus top-level keys it doesn't know (likely typos).
    public static func parse(_ text: String) throws -> (config: RepoConfig, unknownKeys: [String]) {
        let data = Data(text.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError(description: "not a JSON object")
        }
        do {
            let config = try JSONDecoder().decode(RepoConfig.self, from: data)
            return (config, object.keys.filter { !knownKeys.contains($0) }.sorted())
        } catch let DecodingError.keyNotFound(key, context) {
            throw ParseError(description: "missing \((context.codingPath + [key]).map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            throw ParseError(description: "wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw ParseError(description: "\(error)")
        }
    }

    /// Pretty, stable JSON, e.g. for a draft.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}
