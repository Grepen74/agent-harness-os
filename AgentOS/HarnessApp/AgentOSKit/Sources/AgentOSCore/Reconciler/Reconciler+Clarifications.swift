import Foundation

extension Reconciler {
    /// Corrections by number, one per line: `2: answer`, `2. answer` or `2. Answer: answer` (the form question
    /// comments suggest). Nil when the text isn't a numbered reply at all.
    static func corrections(in text: String) -> [(number: Int, answer: String)]? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let parsed = lines.map { line -> (Int, String)? in
            guard let match = line.firstMatch(of: /^(\d+)\s*[:.)]\s*(?:[Aa]nswer\s*:)?(.*)$/), let number = Int(match.1) else {
                return nil
            }
            return (number, String(match.2).trimmingCharacters(in: .whitespaces))
        }
        guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else { return nil }
        return parsed.compactMap { $0 }
    }

    /// The latest human comment since the newest suggestions, when it's a numbered correction.
    static func latestCorrectionComment(on ticket: Ticket, for node: NodeState) -> Comment? {
        guard let newest = node.suggestedAnswers.values.map(\.reportedAt).max(),
              let comment = ticket.comments.last(where: { $0.author.isHuman && $0.at >= newest }),
              corrections(in: comment.text) != nil else { return nil }
        return comment
    }

    func correctSuggestion(on node: NodeState, ticket: Ticket, in state: WorkingState) async throws -> String {
        let guidance = "To correct a suggested answer, comment with its number from the latest " +
            "\"Proceeding on suggested answers\" list, one per line, e.g. `2: <correct answer>`, then add harness:retry. " +
            "If the work stopped for another reason, comment what to change without numbers and add harness:retry."
        guard let (role, suggestions) = node.suggestedAnswers.max(by: { $0.value.reportedAt < $1.value.reportedAt }),
              let comment = ticket.comments.last(where: { $0.author.isHuman && $0.at >= suggestions.reportedAt }),
              let corrections = Self.corrections(in: comment.text),
              corrections.allSatisfy({ $0.number > 0 && $0.number <= suggestions.questions.count && !$0.answer.isEmpty })
        else {
            throw Rejection(reason: guidance)
        }
        if role == .decomposer, let started = state.subtree(of: node.id).first(where: Self.hasStartedBuilding) {
            throw Rejection(reason: "Building has started on \(workLink(started)), so this breakdown cannot be corrected. " +
                "Open a follow-up ticket for the corrected work.")
        }
        if role == .testAuthor, node.landedCommit != nil || node.phase == .proven {
            throw Rejection(reason: "\(workLink(node)) has already landed and cannot be changed. " +
                "Open a follow-up ticket for the corrected work.")
        }
        guard node.activeRun == nil else {
            throw Rejection(reason: "An agent is still running on \(workLink(node)). Wait for it to finish, then add harness:retry.")
        }
        if role == .testAuthor { try await workspace.removeWorktree(for: node.id) }
        var spec = node.spec
        if role == .decomposer { spec.kind = .composite }
        // Replanning preserves clarifications and children; restore only gates the person already approved.
        let kinds: [EventKind] = corrections.map {
            .questionsAnswered(Clarification(questions: [suggestions.questions[$0.number - 1].question], answer: $0.answer))
        } + [.replanned(spec: spec)] + Gate.allCases.filter(node.gates.contains).map { .gateOpened($0) }
        try await write(node.id, by: comment.author, kinds, expecting: node.version)
        return role == .decomposer
            ? "correction recorded; decomposition will rerun, retaining unchanged children and their tests and approvals"
            : "correction recorded; the old working copy was discarded and test authoring will restart from the latest landing branch"
    }

    /// `harness:retry` on a node waiting for input: the human comments since the harness asked are the answer.
    /// Without open questions it was waiting for a review of its tests, so the answer is feedback on them and
    /// the tests are written again with it.
    func resume(_ node: NodeState, answeredOn ticket: Ticket, by person: String) async throws -> String {
        if await isWaitingOnOtherTest(node) {
            // The person may have fixed the other test instead of answering; the implementer tries again either way.
            var kinds: [EventKind] = [.flagCleared(.needsInput)]
            if let answer = Self.answer(on: ticket) {
                kinds.insert(.questionsAnswered(Clarification(questions: ["How to proceed with the conflicting test"], answer: answer)), at: 0)
            }
            if node.flags[.escalated] != nil { kinds += [.flagCleared(.escalated), .attemptsReset] }
            // Pick up a fix to the other test made since; the implementation was already discarded, the tests are kept.
            let directory = workspace.worktree(for: node.id)
            _ = try await workspace.rebaseOntoMain(directory)
            try await write(node.id, by: .human(person), kinds)
            return "the implementer will try again on the latest landing branch"
        }
        if await isDisputingReviewFindings(node) {
            guard let answer = Self.answer(on: ticket) else {
                throw Rejection(reason: "Comment how to proceed with the review findings first, then add harness:retry " +
                    "again. If they are about the acceptance tests, add harness:retest instead.")
            }
            var kinds: [EventKind] = [
                .questionsAnswered(Clarification(questions: ["How to proceed with the change review's findings"], answer: answer)),
                .flagCleared(.needsInput)]
            if node.flags[.escalated] != nil { kinds += [.flagCleared(.escalated), .attemptsReset] }
            try await write(node.id, by: .human(person), kinds)
            return "answer recorded; the implementer will try again with it"
        }
        guard let answer = Self.answer(on: ticket) else {
            // Stopped by the acceptance-test compile check (tests not yet accepted): the person may have fixed the
            // tests or the harness, so the test author runs again without needing a comment.
            if node.openQuestions.isEmpty && node.spec.kind == .leaf && node.phase == .specified {
                var kinds: [EventKind] = [.flagCleared(.needsInput)]
                if node.flags[.escalated] != nil { kinds += [.flagCleared(.escalated), .attemptsReset] }
                try await write(node.id, by: .human(person), kinds)
                return "the test author will write the acceptance tests again"
            }
            throw Rejection(reason: "Answer \(node.openQuestions.isEmpty ? "the review request" : "the questions") above in a comment " +
                "first, then add harness:retry again. To build the tests as they are, add harness:build instead.")
        }
        let isReview = node.openQuestions.isEmpty
        let answers = try isReview
            ? [Clarification(questions: ["Feedback on the acceptance tests"], answer: answer)]
            : Self.resolveAnswers(answer, to: node.openQuestions, signal: .retry)
        var kinds: [EventKind] = answers.map { .questionsAnswered($0) } + [.flagCleared(.needsInput)]
        if isReview && node.spec.kind == .leaf && node.phase == .ready {
            try? await workspace.removeWorktree(for: node.id)
            kinds.append(.phaseChanged(to: .specified))
        }
        if node.flags[.escalated] != nil { kinds += [.flagCleared(.escalated), .attemptsReset] }
        try await write(node.id, by: .human(person), kinds)
        return isReview ? "feedback recorded; the acceptance tests will be written again with it" : "answer recorded; work continues with it"
    }

    /// Human comments after the harness's latest "Needs input" comment, or nil when nobody answered yet.
    static func answer(on ticket: Ticket) -> String? {
        guard let asked = ticket.comments.lastIndex(where: { !$0.author.isHuman && $0.text.contains(needsInputMarker) }) else { return nil }
        let replies = ticket.comments[(asked + 1)...].filter(\.author.isHuman).map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return replies.isEmpty ? nil : replies.joined(separator: "\n\n")
    }

    static let needsInputMarker = "❓ Needs input"
    static let previewQuestionsMarker = "❓ The decomposer has questions before it can propose a breakdown"

    private static func resolveAnswers(
        _ reply: String, to questions: [AgentQuestion], signal: HarnessCommand
    ) throws -> [Clarification] {
        let pattern = #"(?:^|[,\r\n])\s*(\d+)\.\s*Answer:\s*"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let text = reply as NSString
        let matches = regex.matches(in: reply, range: NSRange(location: 0, length: text.length))
        let acceptsSuggestions = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "ok"
        if matches.isEmpty && !acceptsSuggestions {
            return [Clarification(questions: questions.map(\.question), answer: reply)]
        }
        var corrections: [Int: String] = [:]
        for (index, match) in matches.enumerated() {
            guard let number = Int(text.substring(with: match.range(at: 1))),
                  questions.indices.contains(number - 1) else {
                throw Rejection(reason: "A correction names an unknown question. Use the original question numbers, then add \(signal.label).")
            }
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : text.length
            let answer = text.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else {
                throw Rejection(reason: "Question \(number) needs answer text. Reply '\(number). Answer: <answer>', then add \(signal.label).")
            }
            corrections[number] = answer
        }
        let unresolved = questions.indices.filter {
            corrections[$0 + 1] == nil && questions[$0].suggestion == nil
        }
        guard unresolved.isEmpty else {
            let numbers = unresolved.map { String($0 + 1) }.joined(separator: ", ")
            throw Rejection(reason: "Questions \(numbers) are still open. Reply with the remaining original numbers as 'N. Answer: <answer>', then add \(signal.label).")
        }
        return questions.enumerated().compactMap { index, question in
            (corrections[index + 1] ?? question.suggestion).map {
                Clarification(questions: [question.question], answer: $0)
            }
        }
    }

    /// Answers to a preview's questions: the human comments after each such question comment (up to the next
    /// one), with the questions it asked. Those the node doesn't have yet.
    static func newPreviewAnswers(on ticket: Ticket, for node: NodeState?) throws -> [Clarification] {
        var answers: [Clarification] = []
        var asked: [AgentQuestion]?
        var replies: [String] = []
        func flush() throws {
            if let asked, !replies.isEmpty {
                answers += try resolveAnswers(replies.joined(separator: "\n\n"), to: asked, signal: .preview)
            }
            replies = []
        }
        for comment in ticket.comments {
            if !comment.author.isHuman && comment.text.contains(previewQuestionsMarker) {
                try flush()
                var questions: [AgentQuestion] = []
                for line in comment.text.split(separator: "\n") {
                    if let match = line.firstMatch(of: /^\d+\.\s+(.+)$/) {
                        questions.append(AgentQuestion(question: String(match.output.1)))
                    } else if let last = questions.indices.last,
                              let range = line.range(of: "   Suggested answer: ") {
                        questions[last].suggestion = String(line[range.upperBound...])
                    }
                }
                asked = questions
            } else if asked != nil, comment.author.isHuman {
                let text = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { replies.append(text) }
            }
        }
        try flush()
        return answers.filter { !(node?.clarifications.contains($0) ?? false) }
    }

    /// Adopting or approving keeps the answers given to previews, for every agent that works on it later.
    /// The agent can't go on without a person: record its questions and ask on the ticket.
    func raise(
        _ questions: [AgentQuestion],
        on node: NodeState,
        by author: Participant,
        run: RunID,
        role: AgentRole,
        additionalKinds: [EventKind] = []
    ) async throws -> String {
        let plural = questions.count == 1 ? "question" : "questions"
        try await write(node.id, by: author, [
            .runFinished(run: run, outcome: "asked \(questions.count) \(plural)"), .questionsRaised(role: role, questions: questions),
            .flagSet(.needsInput, reason: "\(questions.count) open \(plural) from the \(role.title)")
        ] + additionalKinds)
        await tracker.comment(on: node.ticket, """
            \(Self.needsInputMarker): the \(role.title) can't go on without answers.
            \(Self.numbered(questions))
            \(Self.questionReplyInstructions(for: questions, then: .retry))
            """)
        return "\(node.displayName) needs input: \(questions.count) \(plural) from the \(role.title)"
    }

    static func numbered(_ items: [AgentQuestion]) -> String {
        items.enumerated().map { index, item in
            let suggestion = item.suggestion.map { "\n   Suggested answer: \($0)" } ?? ""
            return "\(index + 1). \(item.question)\(suggestion)"
        }.joined(separator: "\n")
    }

    static func questionReplyInstructions(for questions: [AgentQuestion], then command: HarnessCommand) -> String {
        let suggested = questions.filter { $0.suggestion != nil }.count
        if suggested == 0 {
            return "Answer them in a comment, e.g. `1. Answer: <answer text>, 2. Answer: <answer text>`. " +
                "Then add \(command.label)."
        }
        let unsuggested = suggested == questions.count ? "" :
            " Questions without a suggested answer must be answered in writing."
        return "Answer them in a comment: reply `ok` to accept all suggested answers, or use " +
            "`1. Answer: <answer text>, 2. Answer: <answer text>` to correct selected answers " +
            "while accepting the remaining suggestions.\(unsuggested) Then add \(command.label)."
    }

    func postProceedingOnSuggestions(_ questions: [AgentQuestion], on ticket: String) async {
        guard !questions.isEmpty, questions.allSatisfy({ $0.suggestion != nil }) else { return }
        await tracker.comment(on: ticket, """
            💡 Proceeding on suggested answers:
            \(Self.numbered(questions))
            To correct one, comment with its number and the corrected answer, then add harness:retry.
            """)
    }

    func recordSuggestions(_ questions: [AgentQuestion], on node: NodeState,
                                   role: AgentRole, by author: Participant) async throws {
        let suggestions = questions.allSatisfy { $0.suggestion != nil } ? questions : []
        try await write(node.id, by: author, [.suggestionsReported(role: role, questions: suggestions)])
        await postProceedingOnSuggestions(suggestions, on: node.ticket)
    }

    /// An empty string without assumptions; otherwise a section to append to a comment.
    static func assumptionsNote(_ heading: String, _ assumptions: [String]) -> String {
        assumptions.isEmpty ? "" : "\n📝 \(heading):\n" + assumptions.map { "- \($0)" }.joined(separator: "\n")
    }
}
