@testable import AgentOSAdapters
import AgentOSCore
import Foundation
import Testing

@Suite("Copilot reviewer")
struct CopilotReviewerTests {
    static let spec = NodeSpec(id: "wn-GH-9", parent: nil, kind: .leaf, title: "Branches",
                               intent: "Requirement branches", acceptanceCriteria: ["Older tests expect requirement branches"])

    @Test("An answer without the JSON gets the reviewer asked once more, and both answers are kept in its log")
    func anAnswerWithoutJSONIsAskedForAgain() async throws {
        let fixture = try Fixture(answers: ["I reviewed the tests and they look fine.",
                                            #"{"passed": true, "findings": [], "testFindings": [], "followUps": []}"#])
        defer { fixture.remove() }

        let result = try await fixture.reviewer.review(fixture.request)

        #expect(result.passed)
        let prompts = try fixture.prompts()
        #expect(prompts.count == 2)
        #expect(!prompts[0].contains(CopilotReviewer.jsonReminder) && prompts[1].contains(CopilotReviewer.jsonReminder))
        let first = try String(contentsOf: fixture.log, encoding: .utf8)
        let retry = try String(contentsOf: fixture.directory.appending(path: "review-retry.log"), encoding: .utf8)
        #expect(first.contains("they look fine") && retry.contains(#""passed": true"#))
    }

    @Test("A reviewer that twice answers without the JSON fails with the end of its answer and where the rest is")
    func twoAnswersWithoutJSONFailWithWhatItSaid() async throws {
        let fixture = try Fixture(answers: ["Too much to review.", "Still too much to review."])
        defer { fixture.remove() }

        await #expect {
            try await fixture.reviewer.review(fixture.request)
        } throws: { error in
            let message = "\(error)"
            return message.hasPrefix("Reviewer did not return a JSON review result.")
                && message.contains(#"ended with: "Still too much to review.""#) && message.contains(fixture.log.path)
        }
        #expect(try fixture.prompts().count == 2)
    }

    @Test("The ticket's own tests are shown in full; other work's tests it updated only by path, their changes in the diff")
    func otherWorksUpdatedTestsAreShownByPathOnly() {
        let request = ReviewRequest(
            stage: .acceptanceTests, spec: Self.spec,
            acceptanceTests: ["Tests/GH_9Tests/GH_9Tests.swift": "OWN TEST BODY",
                              "Tests/GH_4Tests/GH_4Tests.swift": "OLDER TEST BODY"],
            context: ReviewContext(baseBranch: "main", commit: "c", fullDiff: "+OLDER CHANGE", changedFiles: [],
                                   recentChanges: [], uiEvidence: nil),
            testFolder: "Tests/GH_9Tests/")

        let prompt = CopilotReviewer.prompt(for: request)

        #expect(prompt.contains("OWN TEST BODY") && prompt.contains("+OLDER CHANGE"))
        #expect(!prompt.contains("OLDER TEST BODY"))
        #expect(prompt.contains("Tests/GH_4Tests/GH_4Tests.swift: another work's test this ticket updated"))
    }
}

private extension CopilotReviewerTests {
    /// A fake copilot that gives the answers in turn and keeps each prompt it was given.
    struct Fixture {
        let directory: URL
        let log: URL
        let reviewer: CopilotReviewer
        let request: ReviewRequest

        init(answers: [String]) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "agentos-reviewer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, answer) in answers.enumerated() {
                try answer.write(to: directory.appending(path: "answer-\(index + 1)"), atomically: true, encoding: .utf8)
            }
            let copilot = directory.appending(path: "copilot")
            try """
            #!/bin/sh
            n=$(ls "\(directory.path)" | grep -c '^prompt-')
            n=$((n + 1))
            printf '%s' "$2" > "\(directory.path)/prompt-$n"
            cat "\(directory.path)/answer-$n"
            """.write(to: copilot, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot.path)
            log = directory.appending(path: "review.log")
            reviewer = CopilotReviewer(cli: CopilotCLI(executable: copilot.path, timeout: .seconds(600)))
            request = ReviewRequest(
                stage: .acceptanceTests, spec: CopilotReviewerTests.spec, acceptanceTests: [:],
                context: ReviewContext(baseBranch: "main", commit: "c", fullDiff: "", changedFiles: [],
                                       recentChanges: [], uiEvidence: nil),
                directory: directory, log: log)
        }

        func prompts() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("prompt-") }.sorted()
                .map { try String(contentsOf: directory.appending(path: $0), encoding: .utf8) }
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
