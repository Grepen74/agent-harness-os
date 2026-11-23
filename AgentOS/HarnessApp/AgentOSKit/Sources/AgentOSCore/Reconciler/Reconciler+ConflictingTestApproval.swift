extension Reconciler {
    /// Resolve the reported conflict through the same boundary used to keep and verify test-author updates.
    private func conflictingTestUpdateTarget(
        _ node: NodeState?, in state: WorkingState
    ) async throws(Rejection) -> String {
        guard let node, await isWaitingOnOtherTest(node), let report = node.brokenTestReports.last else {
            throw Rejection(reason: "This ticket isn't waiting on another conflicting test.")
        }
        let directory = workspace.worktree(for: node.id)
        guard let file = report.testFile ?? declaringFiles(of: report.testName, in: directory).sorted().first else {
            throw Rejection(reason: "No file could be found for the conflicting test \(report.testName). " +
                "Correct the test report or fix the test on the default branch, then add harness:retry.")
        }
        guard allowedOtherTestUpdates([file], of: node).contains(file) else {
            throw Rejection(reason: "\(file) is outside the updatable test areas or matches a protected path; " +
                "no agent may change that test.")
        }
        let owners = state.nodes.values.filter { owner in
            let folder = workspace.testFolder(for: owner.spec)
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            return owner.id != node.id && owner.landedCommit == nil && file.hasPrefix(prefix)
        }.map(\.ticket).sorted()
        guard owners.isEmpty else {
            throw Rejection(reason: "\(owners.joined(separator: ", ")) owns \(file) and hasn't landed. " +
                "Wait for that work to land before approving its test update.")
        }
        return file
    }

    func approveConflictingTest(
        _ node: NodeState?, ticket: Ticket, by person: String, in state: WorkingState
    ) async throws -> String {
        let file = try await conflictingTestUpdateTarget(node, in: state)
        guard let node, let report = node.brokenTestReports.last else {
            throw Rejection(reason: "This ticket isn't waiting on another conflicting test.")
        }
        var kinds: [EventKind] = [.testUpdatesApproved(files: [file])]
        if let answer = Self.answer(on: ticket) {
            kinds.append(.questionsAnswered(Clarification(
                questions: ["How to proceed with the conflicting test"], answer: answer)))
        }
        kinds.append(.flagCleared(.needsInput))
        if node.flags[.escalated] != nil { kinds += [.flagCleared(.escalated), .attemptsReset] }
        kinds += [
            .brokenTestRouted(testName: report.testName, outcome: .sentBackToTestAuthor),
            .phaseChanged(to: .specified),
        ]
        try await write(node.id, by: .human(person), kinds, expecting: node.version)
        return "approval recorded for \(file); the test author will update it on this ticket's branch" +
            " with any guidance you commented"
    }

    /// Broken-test guidance needs the ledger's routing outcome and the repository's update boundaries.
    func nextSteps(for ticket: String, in state: WorkingState) async -> [String] {
        guard let node = state.node(forTicket: ticket), await isWaitingOnOtherTest(node) else {
            return Self.nextSteps(for: ticket, in: state, allowed: policy.allowedSignals)
        }
        var steps: [String] = []
        do {
            let file = try await conflictingTestUpdateTarget(node, in: state)
            if policy.allowedSignals.contains(.updateTest) {
                steps.append("harness:update-test to approve updating \(file) by the test author on this ticket's branch " +
                    "(add an optional guidance comment first)")
            }
        } catch {
            steps.append(error.reason)
        }
        if policy.allowedSignals.contains(.retry) {
            steps.append("Change the test on the default branch and commit; once the harness catches up, add harness:retry. " +
                "Or comment how to proceed, then add harness:retry.")
        }
        return steps
    }
}
