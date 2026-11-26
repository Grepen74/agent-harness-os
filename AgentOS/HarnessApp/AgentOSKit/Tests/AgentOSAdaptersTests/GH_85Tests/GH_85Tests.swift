// API contract: AgentRunRecording.aiCredits: Double? exposes the sum of AI credits
// reported by Copilot CLI attempts in that run, including nested CopilotReviewer
// attempts, while fellBack continues to describe only the enclosing role.
// nil means no attempt reported usage; a reported zero is not missing usage.
// CLI fixtures end with the CLI's usage summary, "AI Credits <number> (<duration>)", on stdout or stderr.
// AC5 (docs/real-repo-mode.md explaining per-run CLI credits in the ledger)
// is documentation-only and must be checked in the implementation diff.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite(.timeLimit(.minutes(1)))
struct GH_85Tests {
    @Test("Fixture probe: the executable supplies real output and model/effort fallback signals")
    func scriptedCLIExercisesExistingExecutionAndFallbackBehavior() async throws {
        let fixture = try Fixture(script: """
            case "$model/$effort" in
              gone/*)
                echo 'Execution failed: Model "gone" is not available.'
                exit 1 ;;
              working/high)
                echo "Execution failed: Reasoning effort 'high' is not supported for model 'working'."
                exit 1 ;;
            esac
            echo 'fixture response'
            echo 'AI Credits 0.5 (12s)' >&2
            """)
        defer { fixture.remove() }

        let raw = try await ProcessRunner.run(fixture.executable.path, [], in: fixture.directory)
        try #require(raw.status == 0)
        try #require(raw.output.contains("fixture response"))
        try #require(raw.output.contains("AI Credits 0.5 (12s)"))

        let cli = fixture.cli(model: "gone", fallbackModels: ["working"], effort: .high)
        let recording = AgentRunRecording()
        let run = try await AgentRunRecording.$current.withValue(recording) {
            try await cli.runFallingBack("fixture probe", in: fixture.directory)
        }
        #expect(run.output.contains("fixture response"))
        #expect(run.model == "working")
        #expect(run.unavailableModels == ["gone"])
        #expect(run.settings.effort == "the CLI's default")
        #expect(recording.fellBack == run.settings)
        #expect(try fixture.attempts() == ["default/default", "gone/high", "working/high", "working/default"])
    }

    @Test("AC1: a run reports the CLI's actual fractional, singular, or zero AI credits",
          arguments: [
            Usage(summary: "AI Credits 0 (3s)", amount: 0),
            Usage(summary: "AI Credits 24.25 (6m 54s)", amount: 24.25),
            Usage(summary: "AI Credits 1,204.5 (1h 2m 3s)", amount: 1204.5),
            Usage(summary: "Total usage est:        1 AI credit", amount: 1),
            Usage(summary: "Total usage est:        2.125 AI credits", amount: 2.125),
          ], [false, true])
    func reportedCreditsAreNotEstimatedFromTokensOrModel(
        usage: Usage, summaryOnStderr: Bool
    ) async throws {
        let fixture = try Fixture(script: """
            echo 'finished'
            echo 'Total tokens: 9000000'
            echo '\(usage.summary)' \(summaryOnStderr ? ">&2" : "")
            """)
        defer { fixture.remove() }
        let recording = AgentRunRecording()

        _ = try await AgentRunRecording.$current.withValue(recording) {
            try await fixture.cli(model: "arbitrary-model").runFallingBack("work", in: fixture.directory)
        }

        #expect(recording.aiCredits == usage.amount)
        #expect(recording.fellBack == nil)
    }

    @Test("AC1: reported credits remain available even when the CLI exits unsuccessfully")
    func reportedCreditsAreRetainedWhenTheAttemptFails() async throws {
        let fixture = try Fixture(script: """
            echo 'Execution failed: agent stopped before completing the task.'
            echo 'AI Credits 0.375 (12s)' >&2
            exit 1
            """)
        defer { fixture.remove() }
        let recording = AgentRunRecording()

        await AgentRunRecording.$current.withValue(recording) {
            await #expect(throws: AgentFailure.self) {
                try await fixture.cli().runFallingBack("work", in: fixture.directory)
            }
        }

        #expect(recording.aiCredits == 0.375)
    }

    @Test("AC2: every model and reasoning-effort fallback attempt contributes its reported credits",
          arguments: Fallback.allCases)
    func fallbackAttemptsAddCreditsInsteadOfReplacingThem(fallback: Fallback) async throws {
        let fixture = try Fixture(script: """
            case "$model/$effort" in
              gone/*)
                echo 'AI Credits 0.125 (12s)'
                echo 'Execution failed: Model "gone" is not available.' >&2
                exit 1 ;;
              working/high)
                echo 'AI Credits 0.375 (12s)' >&2
                echo "Execution failed: Reasoning effort 'high' is not supported for model 'working'."
                exit 1 ;;
            esac
            echo 'finished'
            echo 'AI Credits 1.5 (12s)'
            """)
        defer { fixture.remove() }
        let recording = AgentRunRecording()
        let cli = fixture.cli(
            model: fallback == .effort ? "working" : "gone",
            fallbackModels: ["working"],
            effort: fallback == .model ? nil : .high)

        let run = try await AgentRunRecording.$current.withValue(recording) {
            try await cli.runFallingBack("work", in: fixture.directory)
        }

        try #require(run.model == "working")
        #expect(run.output.contains("finished"))
        #expect(recording.aiCredits == fallback.expectedCredits)
        #expect(recording.fellBack == run.settings)
        #expect(try fixture.attempts() == fallback.expectedAttempts)
    }

    @Test("AC2: credits from fallback attempts are retained if all candidate models fail")
    func exhaustedFallbackStillReportsTheCreditsAlreadyUsed() async throws {
        let fixture = try Fixture(script: """
            case "$model" in
              gone) echo 'AI Credits 0.125 (12s)' ;;
              also-gone) echo 'AI Credits 0.375 (12s)' ;;
              *) exit 2 ;;
            esac
            printf 'Execution failed: Model "%s" is not available.\\n' "$model" >&2
            exit 1
            """)
        defer { fixture.remove() }
        let recording = AgentRunRecording()

        await AgentRunRecording.$current.withValue(recording) {
            await #expect(throws: AgentFailure.self) {
                try await fixture.cli(model: "gone", fallbackModels: ["also-gone"])
                    .runFallingBack("work", in: fixture.directory)
            }
        }

        #expect(recording.aiCredits == 0.5)
        #expect(try fixture.attempts() == ["gone/default", "also-gone/default"])
    }

    @Test("AC3: a nested review's fallback credits count without replacing the enclosing role's fallback",
          arguments: [false, true])
    func nestedReviewAddsCreditsButKeepsItsSettingsOutOfTheEnclosingRecord(
        enclosingRoleFallsBack: Bool
    ) async throws {
        let fixture = try Fixture(script: """
            case "$model/$effort" in
              worker-gone/*)
                echo 'AI Credits 0.25 (12s)'
                echo 'Execution failed: Model "worker-gone" is not available.'
                exit 1 ;;
              worker/*)
                echo 'worker finished'
                echo 'AI Credits 0.75 (12s)' ;;
              reviewer-gone/*)
                echo 'AI Credits 0.125 (12s)'
                echo 'Execution failed: Model "reviewer-gone" is not available.'
                exit 1 ;;
              reviewer/high)
                echo 'AI Credits 0.375 (12s)'
                echo "Execution failed: Reasoning effort 'high' is not supported for model 'reviewer'."
                exit 1 ;;
              reviewer/default)
                echo '{"passed":true,"findings":[]}'
                echo 'AI Credits 0.5 (12s)' ;;
              *) exit 2 ;;
            esac
            """)
        defer { fixture.remove() }
        let recording = AgentRunRecording()
        let worker = fixture.cli(model: enclosingRoleFallsBack ? "worker-gone" : "worker",
                                 fallbackModels: ["worker"])
        let reviewer = CopilotReviewer(cli: fixture.cli(
            model: "reviewer-gone", fallbackModels: ["reviewer"], effort: .high))

        try await AgentRunRecording.$current.withValue(recording) {
            let ownRun = try await worker.runFallingBack("work", in: fixture.directory)
            let ownFallback = recording.fellBack
            try #require(ownRun.output.contains("worker finished"))
            #expect(ownFallback == (enclosingRoleFallsBack ? ownRun.settings : nil))

            let review = try await reviewer.review(Self.reviewRequest(in: fixture.directory))

            #expect(review.passed)
            #expect(review.model == "reviewer")
            #expect(review.unavailableModels == ["reviewer-gone"])
            #expect(review.settings?.model == "reviewer")
            #expect(review.settings?.effort == "the CLI's default")
            #expect(review.settings?.fallback?.isEmpty == false)
            #expect(recording.aiCredits == (enclosingRoleFallsBack ? 2 : 1.75))
            #expect(recording.fellBack == ownFallback,
                    "The reviewer's model and effort fallback belong only to its ReviewResult")
        }
    }

    @Test("AC3: verification with only a reviewer still reports the review's credits")
    func aReviewerIsChargedToAnOtherwiseEmptyEnclosingRun() async throws {
        let fixture = try Fixture(script: """
            echo '{"passed":true,"findings":[]}'
            echo 'AI Credits 0.625 (12s)' >&2
            """)
        defer { fixture.remove() }
        let recording = AgentRunRecording()

        let result = try await AgentRunRecording.$current.withValue(recording) {
            try await CopilotReviewer(cli: fixture.cli(model: "reviewer"))
                .review(Self.reviewRequest(in: fixture.directory))
        }

        #expect(result.passed)
        #expect(recording.aiCredits == 0.625)
        #expect(recording.fellBack == nil)
    }

    @Test("A real Copilot CLI run's tail: the closing summary counts, not one the agent's answer quotes")
    func realCLISummaryIsReadAfterTheAnswer() {
        let output = """
            Implemented GH-155: bundled build stamps and per-session Copilot version detection.
            The old parser expected lines like:
            AI Credits 3 (1m 2s)

            Changes    +101 -1
            AI Credits 24.25 (6m 54s)
            Tokens     ↑ 678.9k (627.0k cached, 51.9k written) • ↓ 5.0k (927 reasoning)
            Resume     copilot --resume=8f6b36e3-4246-4604-92eb-e82eaecb0d54

            """

        #expect(CopilotCLI.aiCredits(in: output) == 24.25)
        #expect(CopilotCLI.aiCredits(in: "AI Credits were not reported\nTokens ↑ 1k") == nil)
    }

    @Test("AC4: without reported usage, success, failure, crash, and timeout all leave credits unknown",
          arguments: MissingUsage.allCases)
    func missingUsageIsNilNotZeroOrAnEstimate(ending: MissingUsage) async throws {
        let fixture = try Fixture(script: """
            echo 'Total tokens: 42000'
            \(ending.script)
            """)
        defer { fixture.remove() }
        let recording = AgentRunRecording()
        let cli = fixture.cli(model: "a-model-with-a-known-price", timeout: ending == .timeout ? .seconds(2) : .seconds(20))

        try await AgentRunRecording.$current.withValue(recording) {
            if ending == .success {
                let run = try await cli.runFallingBack("work", in: fixture.directory)
                #expect(run.output.contains("finished"))
            } else {
                do {
                    _ = try await cli.runFallingBack("work", in: fixture.directory)
                    Issue.record("The fixture must exercise the requested unsuccessful ending")
                } catch let failure as AgentFailure {
                    #expect(failure.description.contains(ending == .timeout ? "timed out" : "exited"))
                }
            }
        }

        #expect(recording.aiCredits == nil, "Absent CLI usage must not be recorded as free or estimated from tokens")
    }

    @Test("AC4: a later run without usage does not inherit the previous run's credits")
    func separateRunRecordingsDoNotShareUsage() async throws {
        let fixture = try Fixture(script: """
            echo 'finished'
            if [ "$model" = reported ]; then
              echo 'AI Credits 0.875 (12s)'
            fi
            """)
        defer { fixture.remove() }
        let reported = AgentRunRecording()
        _ = try await AgentRunRecording.$current.withValue(reported) {
            try await fixture.cli(model: "reported").runFallingBack("work", in: fixture.directory)
        }
        #expect(reported.aiCredits == 0.875)

        let missing = AgentRunRecording()
        _ = try await AgentRunRecording.$current.withValue(missing) {
            try await fixture.cli(model: "unreported").runFallingBack("work", in: fixture.directory)
        }

        #expect(missing.aiCredits == nil)
        #expect(reported.aiCredits == 0.875)
    }

    private static func reviewRequest(in directory: URL) -> ReviewRequest {
        ReviewRequest(
            stage: .change,
            spec: NodeSpec(id: "wn-GH-85", kind: .leaf, title: "Reporting run credits",
                           intent: "Calculate task cost", acceptanceCriteria: ["Report CLI usage"]),
            acceptanceTests: [:],
            context: ReviewContext(baseBranch: "agentos/main", commit: "candidate", fullDiff: "", changedFiles: [],
                                   recentChanges: [], uiEvidence: nil),
            directory: directory)
    }

    struct Usage: Sendable {
        let summary: String
        let amount: Double
    }

    enum Fallback: CaseIterable, Sendable {
        case model, effort, modelAndEffort

        var expectedCredits: Double {
            switch self {
            case .model: 1.625
            case .effort: 1.875
            case .modelAndEffort: 2
            }
        }

        var expectedAttempts: [String] {
            switch self {
            case .model: ["gone/default", "working/default"]
            case .effort: ["working/high", "working/default"]
            case .modelAndEffort: ["gone/high", "working/high", "working/default"]
            }
        }
    }

    enum MissingUsage: CaseIterable, Sendable {
        case success, failure, crash, timeout

        var script: String {
            switch self {
            case .success: "echo finished"
            case .failure: "echo 'Execution failed' >&2\nexit 1"
            case .crash: "kill -KILL $$"
            case .timeout:
                // Only the adapter's timeout can end this blocked attempt.
                """
                mkfifo "$dir/hold"
                IFS= read -r ignored < "$dir/hold"
                """
            }
        }
    }

    private struct Fixture {
        let directory: URL
        var executable: URL { directory.appending(path: "copilot") }

        init(script: String) throws {
            var root = URL(filePath: #filePath)
            for _ in 0..<7 { root.deleteLastPathComponent() }
            directory = root.appending(path: ".agentos/scratch/run-6eb182/GH-85-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let program = """
                #!/bin/sh
                dir="$(dirname "$0")"
                model=default
                effort=default
                while [ "$#" -gt 0 ]; do
                  case "$1" in
                    --model) model="$2"; shift ;;
                    --reasoning-effort) effort="$2"; shift ;;
                  esac
                  shift
                done
                printf '%s/%s\\n' "$model" "$effort" >> "$dir/attempts.log"
                \(script)

                """
            try program.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        func cli(model: String? = nil, fallbackModels: [String?] = [], effort: ReasoningEffort? = nil,
                 timeout: Duration = .seconds(20)) -> CopilotCLI {
            var cli = CopilotCLI(executable: executable.path, model: model, fallbackModels: fallbackModels,
                                 effort: effort, timeout: timeout)
            cli.cliSettings = directory.appending(path: "missing-settings.json")
            cli.environment = [:]
            return cli
        }

        func attempts() throws -> [String] {
            try String(contentsOf: directory.appending(path: "attempts.log"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
