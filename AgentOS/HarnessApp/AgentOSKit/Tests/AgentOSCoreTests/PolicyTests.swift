import Foundation
import Testing
@testable import AgentOSCore

@Suite("Repo config and policy")
struct PolicyTests {
    func resolve(_ repo: RepoConfig?) -> EffectivePolicy {
        EffectivePolicy.resolve(harness: HarnessSettings(), repo: repo, defaultBranch: "main")
    }

    func config(limits: RepoConfig.Limits? = nil, landing: String? = nil, disable: [String]? = nil) -> RepoConfig {
        RepoConfig(test: .init(command: "swift test"), landing: landing.map { .init(branch: $0) },
                   signals: disable.map { .init(disable: $0) }, limits: limits)
    }

    @Test func withoutARepoConfigTheHarnessSettingsApply() {
        let policy = resolve(nil)
        #expect(policy.problems.isEmpty)
        #expect(policy.landingBranch == "agentos/main")
        #expect(policy.policy.allowedSignals == Set(HarnessCommand.allCases))
        #expect(policy.settings.allSatisfy { $0.source == .harness })
    }

    @Test func aRepoMayTightenLimits() throws {
        let policy = resolve(config(limits: .init(maxAttempts: 1, maxParallelAgents: 2), landing: "agents/landing", disable: ["harness:go"]))
        #expect(policy.problems.isEmpty)
        #expect(policy.policy.maxAttempts == 1)
        #expect(policy.policy.maxReworks == 3)
        #expect(policy.landingBranch == "agents/landing")
        #expect(!policy.policy.allowedSignals.contains(.go))
        let attempts = try #require(policy.settings.first { $0.name == "Max attempts per leaf" })
        #expect(attempts.source == .repo)
        // Same value as the harness: nothing was changed by the repo.
        #expect(policy.settings.first { $0.name == "Max parallel agents" }?.source == .harness)
    }

    @Test func aRepoCannotLoosenLimitsOrLandOnItsDefaultBranch() {
        let policy = resolve(config(limits: .init(maxAttempts: 10, maxReworks: 0), landing: "main"))
        #expect(policy.problems.map(\.severity) == [.blocker, .blocker, .blocker])
        #expect(policy.policy.maxAttempts == 3)
        #expect(policy.policy.maxReworks == 3)
        #expect(policy.landingBranch == "agentos/main")
        #expect(policy.settings.first { $0.name == "Max attempts per leaf" }?.note == "repo asked for 10: refused")
    }

    @Test func invalidBranchesAndUnknownSignalsAreReported() {
        let policy = resolve(config(landing: "origin/main", disable: ["preview", "merge"]))
        #expect(policy.problems.map(\.severity) == [.blocker, .warning])
        #expect(policy.problems.last?.title == "Repo config disables unknown signals: merge")
        #expect(policy.policy.allowedSignals == Set(HarnessCommand.allCases).subtracting([.preview]))
    }

    @Test func aRepoCanOnlyAddToDeniedToolsAndProtectedPaths() {
        var repo = config()
        repo.agents = .init(deny: ["git push", "rm -rf"])
        repo.protectedPaths = ["Secrets/"]
        let policy = resolve(repo)
        #expect(policy.deniedTools == HarnessSettings.deniedTools + ["rm -rf"])
        #expect(policy.protectedPaths == HarnessSettings.protectedPaths + ["Secrets/"])
    }

    @Test func parsingReportsUnknownKeysAndMissingFields() throws {
        let (config, unknown) = try RepoConfig.parse(#"{"test": {"command": "swift test"}, "tset": 1}"#)
        #expect(config.test.command == "swift test")
        #expect(unknown == ["tset"])
        #expect(throws: RepoConfig.ParseError.self) { try RepoConfig.parse(#"{"build": {"command": "make"}}"#) }
        #expect(throws: RepoConfig.ParseError.self) { try RepoConfig.parse("test: swift test") }
        do {
            _ = try RepoConfig.parse(#"{"test": {}}"#)
            Issue.record("parsed a config without a test command")
        } catch {
            #expect("\(error)" == "missing test.command")
        }
    }

    @Test func baselineIsRecordedInTheLedger() async throws {
        let ledger = try Ledger()
        try await ledger.record(Baseline(commit: "abc", passed: false, summary: "test failed", seconds: 3, log: nil))
        #expect(await ledger.workingState().baseline?.passed == false)
        #expect(await ledger.allRecords().last?.event.kind.summary.contains("FAILED") == true)
    }
}
