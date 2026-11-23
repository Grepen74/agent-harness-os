// Expected API: RequirementPublicationRequest carries a requirement ID, branch tip, optional
// final-verification Evidence and AcceptanceCriterionProof records (1-based criterion, test names).
// PullRequestPublicationCoordinator.reconcile(_:) is the awaited publication step used by harness
// rounds: it uses EffectivePolicy, reads/replays Ledger state, and handles publication harness:retry
// signals through TrackerAdapter. Git commands and GitHubTransport are injectable; neither runs here.
// HarnessSettings.pullRequests is the setting supplied by the preceding setting/verification item.
// The coordinator also conforms to RequirementPublisher, injected via Reconciler's existing publisher:
// argument. Reconciler rounds supply their actual final-verification evidence, gate publication with
// Policy.pullRequests, and route publication harness:retry without rerunning verification or agents.
// All six criteria have observable coverage; there are no documentation-only criteria.
import Foundation
import SwiftUI
import Testing
import AgentOSCore
import AgentOSAdapters
import AgentOSUI
import AgentOSTestSupport

@Suite
struct GH_91Tests {
    @Test(arguments: [false, true])
    func verifiedRequirementsPushOnlyTheirOwnBranchAndOpenOnePRIntoMain(singleLeaf: Bool) async throws {
        let fixture = try await Self.fixture(singleLeaf: singleLeaf)
        let publisher = fixture.publisher()
        try await publisher.reconcile([fixture.request()])

        let pushes = await fixture.git.commands
        try #require(pushes.count == 1, "A verified requirement must be pushed.")
        try Self.expectSafePush(pushes[0], branch: fixture.branch)
        let pr = try #require(Self.single(await fixture.github.pullRequests))
        #expect(pr.head == fixture.branch)
        #expect(pr.base == "main")
        #expect(await fixture.github.operations.firstIndex(where: { $0 == "create" }) != nil)
        #expect(await fixture.git.pushPrecededCreate)
        try await publisher.reconcile([fixture.request()])
        #expect(await fixture.github.pullRequests.count == 1)
        #expect(await fixture.git.commands.count == 1, "An unchanged tip must not be published repeatedly.")
        #expect(await fixture.github.unexpectedRequests.isEmpty)
    }

    @Test
    func theOffSettingKeepsVerifiedWorkLocal() async throws {
        let fixture = try await Self.fixture(enabled: false)
        try await fixture.publisher().reconcile([fixture.request()])
        #expect(await fixture.git.commands.isEmpty)
        #expect(await fixture.github.mutations.isEmpty)
    }

    @Test(arguments: VerificationHold.allCases)
    func nothingIsPublishedUntilEveryLeafAndTheCurrentTipAreVerified(hold: VerificationHold) async throws {
        let fixture = try await Self.fixture(lastLeafProven: hold != .unfinishedLeaf)
        let publisher = fixture.publisher()
        var request = fixture.request()
        switch hold {
        case .unfinishedLeaf: break
        case .notRun: request.verification = nil
        case .failed:
            request.verification = [
                fixture.finalEvidence[0], Self.evidence(fixture.root, check: "build application", passed: false),
            ]
        case .oldCommit:
            request.verification = [
                fixture.finalEvidence[0], Self.evidence(fixture.root, check: "build application", commit: Self.oldCommit),
            ]
        }
        try await publisher.reconcile([request])
        #expect(await fixture.git.commands.isEmpty)
        #expect(await fixture.github.mutations.isEmpty)

        switch hold {
        case .unfinishedLeaf:
            let leaf = try #require(fixture.leaves.last)
            try await fixture.ledger.append([
                LedgerEvent(node: leaf.id, by: .reconciler, kind: .landed(commit: Self.tip)),
                LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
            ])
            try await publisher.reconcile([fixture.request()])
            #expect(await fixture.git.commands.count == 1)
            #expect(await fixture.github.pullRequests.count == 1)
        case .notRun:
            try await publisher.reconcile([fixture.request()])
            #expect(await fixture.git.commands.count == 1)
            #expect(await fixture.github.pullRequests.count == 1)
        case .failed, .oldCommit:
            let verified = try await Self.fixture()
            try await verified.publisher().reconcile([verified.request()])
            #expect(await verified.git.commands.count == 1)
            #expect(await verified.github.pullRequests.count == 1)
        }
    }

    @Test(arguments: [
        "main", "agentos/main", "agentos/leaf/wn-GH-911", "refs/tags/v1",
        "agentos/GH-92", "+agentos/GH-91", "agentos/GH-91:main", "--all",
    ])
    func publicationCannotPushMainLeavesTagsOrAnotherRequirementsBranch(branch: String) async throws {
        let fixture = try await Self.fixture()
        let publisher = fixture.publisher()
        var request = fixture.request()
        request.branch = branch
        try await publisher.reconcile([request])
        #expect(await fixture.git.commands.isEmpty)
        #expect(await fixture.github.mutations.isEmpty)

        let valid = try await Self.fixture()
        try await valid.publisher().reconcile([valid.request()])
        #expect(await valid.git.commands.count == 1, "The guard must still allow a requirement branch.")
    }

    @Test
    func aChildCannotBePublishedAsARequirementEvenWithPassingChecks() async throws {
        let fixture = try await Self.fixture()
        let leaf = fixture.leaves[0]
        var request = fixture.request()
        request.requirement = leaf.id
        request.branch = "agentos/GH-911"
        request.verification = [Self.evidence(leaf, check: "final tests")]
        try await fixture.publisher().reconcile([request])
        #expect(await fixture.git.commands.isEmpty)
        #expect(await fixture.github.mutations.isEmpty)

        try await fixture.publisher().reconcile([fixture.request()])
        #expect(await fixture.git.commands.count == 1, "The top-level requirement, not its child, is publishable.")
    }

    @Test(arguments: [false, true])
    func agentsStillHaveGitPushAndGhDeniedWithPublishingOnOrOff(enabled: Bool) throws {
        let policy = Self.policy(enabled: enabled)
        #expect(policy.deniedTools.contains("git push"))
        #expect(policy.deniedTools.contains("gh"))
        let arguments = CopilotCLI(executable: "unused", deniedTools: policy.deniedTools)
            .arguments(prompt: "Implement this ticket", in: URL(fileURLWithPath: #filePath).deletingLastPathComponent())
        let denied = arguments.indices.compactMap { index -> String? in
            guard arguments[index] == "--deny-tool", arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        #expect(denied.contains("shell(git push)"))
        #expect(denied.contains("shell(gh)"))
    }

    @Test
    func theDescriptionCarriesTheRequirementBreakdownCriterionProofsAndLocalEvidence() async throws {
        let fixture = try await Self.fixture()
        try Self.verifyDescriptionMatchers(fixture)
        let historical = Self.evidence(
            fixture.leaves[0], check: "acceptance tests", passed: false, commit: Self.oldCommit,
            summary: "Acceptance failed", details: "GH_911Tests.rejectsMissingAddress"
        )
        try await Self.record(historical, on: fixture.leaves[0].id, in: fixture.ledger)
        try await fixture.publisher().reconcile([fixture.request()])
        let pr = try #require(Self.single(await fixture.github.pullRequests))
        let body = pr.body
        #expect(body.contains(fixture.root.title))
        #expect(body.contains(fixture.root.intent))
        #expect(body.contains("GH-91"))
        for node in [fixture.root] + fixture.leaves {
            #expect(body.contains(node.title))
            for criterion in node.acceptanceCriteria { #expect(body.contains(criterion)) }
        }
        let criteria = ([fixture.root] + fixture.leaves).flatMap(\.acceptanceCriteria)
        for proof in fixture.proofs {
            let criterion = try #require(([fixture.root] + fixture.leaves).first { $0.id == proof.node })
                .acceptanceCriteria[proof.criterion - 1]
            #expect(Self.proofIsAssociatedWithCriterion(proof.tests, criterion: criterion, among: criteria, in: body),
                    "Test names must be associated with their criterion, not merely listed elsewhere.")
        }
        let checks = fixture.leafEvidence + [historical] + fixture.finalEvidence
        for check in checks {
            #expect(Self.checkIsDescribed(check, among: checks, in: body),
                    "Each check needs its own result, commit, summary, artifact file name and SHA-256.")
        }
        #expect(body.contains("GH_911Tests.rejectsMissingAddress"), "A failed check identifies the failing tests.")
        #expect(body.contains("Closes #91"))
        #expect(await fixture.github.unexpectedRequests.isEmpty, "No uploads or PR merges are allowed.")
    }

    @Test
    func aLongCheckHistoryStillFitsGitHubsLimitKeepingTheFinalVerificationAndLatestResults() async throws {
        let fixture = try await Self.fixture()
        var attempts: [Evidence] = []
        for attempt in 1...100 {
            let evidence = Self.evidence(
                fixture.leaves[0], check: "landing tests", passed: attempt == 100, commit: Self.oldCommit,
                summary: "Attempt \(attempt): " + String(repeating: "output ", count: 300))
            try await Self.record(evidence, on: fixture.leaves[0].id, in: fixture.ledger)
            attempts.append(evidence)
        }
        try await fixture.publisher().reconcile([fixture.request()])
        let body = try #require(Self.single(await fixture.github.pullRequests)).body

        #expect(body.utf16.count <= PullRequestDescription.maximumLength)
        #expect(body.contains("Closes #91"))
        let checks = fixture.leafEvidence + fixture.finalEvidence
        for check in checks { #expect(Self.checkIsDescribed(check, among: checks, in: body)) }
        #expect(body.components(separatedBy: "### full test command").count == 2, "The final verification is listed once.")
        #expect(body.contains(attempts[99].artifactSHA256) && body.contains("the full output is in the evidence file"))
        #expect(!body.contains(attempts[0].artifactSHA256), "The oldest attempts are left out first.")
        #expect(body.contains("left out to fit GitHub's limit"))
    }

    @Test
    func aNonGitHubTrackerDoesNotAccidentallyCloseAnIssueWithTheSameNumber() async throws {
        let fixture = try await Self.fixture(githubTracker: false)
        try await fixture.publisher().reconcile([fixture.request()])
        let pr = try #require(Self.single(await fixture.github.pullRequests))
        #expect(!pr.body.contains("Closes #91"))
    }

    @Test
    func catchUpsAndLaterLandingsPushNewTipsAndUpdateTheSamePRAcrossRestarts() async throws {
        let fixture = try await Self.fixture()
        actor StatusObserver: GitHubTransport {
            struct Status: Sendable { let commit: String; let state: String; let description: String }
            let forwarding: any GitHubTransport
            private(set) var statuses: [Status] = []
            init(forwarding: any GitHubTransport) { self.forwarding = forwarding }
            func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
                let resource = try #require(URLComponents(string: path)).path
                if method == "POST", let marker = resource.range(of: "/statuses/") {
                    let data = try #require(body)
                    var response = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    statuses.append(Status(
                        commit: String(resource[marker.upperBound...]),
                        state: try #require(response["state"] as? String),
                        description: try #require(response["description"] as? String)))
                    response["id"] = statuses.count
                    return try JSONSerialization.data(withJSONObject: response)
                }
                return try await forwarding.request(method, path, body: body)
            }
        }
        struct Refs: RequirementBranchRepository {
            let git: Git
            var defaultBranch: String { "main" }
            func requirementBranch(for ticket: String) -> String { "agentos/\(ticket)" }
            func tip(of branch: String) async throws -> String? {
                branch == defaultBranch ? GH_91Tests.oldCommit : try await git.run(["rev-parse", branch])
            }
            func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
                ancestor == GH_91Tests.oldCommit || ancestor == descendant
            }
            func mergeMain(_ main: String, into branch: String) async throws -> RebaseResult {
                throw AgentFailure("The publication fixture already contains main.")
            }
            func changedFiles(in commit: String) async throws -> [String] { [] }
        }
        struct CheckoutWorkspace: Workspace {
            let base: RoundWorkspace
            let refs: Refs
            func requirementWorktree(for requirement: NodeIdentity) async throws -> URL {
                let commit = try #require(await refs.tip(of: refs.requirementBranch(for: requirement.ticketKey)))
                return base.root.appending(path: commit)
            }
            func head(of directory: URL) async throws -> String { directory.lastPathComponent }
            func requirementIsMerged(_ requirement: NodeIdentity) async throws -> Bool { false }
            func prepare() async throws {}
            func prepareBuild(in directory: URL) async throws {}
            func branch(for id: NodeID) -> String { base.branch(for: id) }
            func worktree(for id: NodeID) -> URL { base.worktree(for: id) }
            var testArea: String { base.testArea }
            var agentContext: String { base.agentContext }
            func testFolder(for spec: NodeSpec) -> String { base.testFolder(for: spec) }
            func existingComponents() -> [String] { [] }
            func changedFiles(in directory: URL) async throws -> [String] { [] }
            func removeWorktree(for id: NodeID) async throws { try await base.removeWorktree(for: id) }
            func abortRebase(_ directory: URL) async throws { try await base.abortRebase(directory) }
            func createWorktree(for id: NodeID) async throws -> URL { try await base.createWorktree(for: id) }
            func commitAll(in directory: URL, message: String, author: String) async throws -> String? {
                try await base.commitAll(in: directory, message: message, author: author)
            }
            func rebaseOntoMain(_ directory: URL) async throws -> RebaseResult { try await base.rebaseOntoMain(directory) }
            func resetForRework(_ directory: URL) async throws { try await base.resetForRework(directory) }
            func landOnMain(_ id: NodeID) async throws -> String { try await base.landOnMain(id) }
        }
        actor FinalChecks: CheckRunner {
            let workspace: CheckoutWorkspace
            private(set) var commits: [String] = []
            init(workspace: CheckoutWorkspace) { self.workspace = workspace }
            func runChecks(in directory: URL, only suite: String?) async -> CheckOutput {
                do {
                    let commit = try await workspace.head(of: directory)
                    #expect(suite == nil)
                    commits.append(commit)
                    return CheckOutput(passed: true, summary: "Full checkout checks passed", log: "Checked \(commit)")
                } catch {
                    Issue.record("Could not inspect the verification checkout: \(error)")
                    return CheckOutput(passed: false, summary: "\(error)", log: "\(error)")
                }
            }
        }
        struct Artifacts: ArtifactStore {
            func put(named name: String, contents: Data) throws -> StoredArtifact {
                StoredArtifact(path: "memory/\(name)", sha256: Hashing.sha256(contents))
            }
        }
        let statuses = StatusObserver(forwarding: fixture.github)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let refs = Refs(git: fixture.git)
        let workspace = CheckoutWorkspace(
            base: RoundWorkspace(root: directory, checkout: directory), refs: refs)
        let checks = FinalChecks(workspace: workspace)
        let agents = RoundAgents()
        func publication(in ledger: Ledger) -> PullRequestPublicationCoordinator {
            PullRequestPublicationCoordinator(
                ledger: ledger, tracker: fixture.tracker, repository: Self.repository,
                policy: Self.policy(enabled: true), transport: statuses,
                git: { try await fixture.git.run($0) })
        }
        func verifyAndPublish(in ledger: Ledger, commit: String) async throws {
            let publisher = publication(in: ledger)
            let reconciler = Reconciler(
                ledger: ledger, tracker: fixture.tracker, external: RoundExternal(),
                workspace: workspace, artifacts: Artifacts(), checks: checks,
                team: AgentTeam(name: "GH-91 reverification", decomposer: agents, testAuthor: agents, implementer: agents),
                policy: Self.policy(enabled: true).policy, requirementBranches: refs,
                publisher: publisher, pullRequests: publisher)
            let count = await checks.commits.count
            try await withHangGuard("GH-91 publishing a reverified tip") {
                while true {
                    let report = await reconciler.runRound(waitForAgents: true)
                    try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
                    if report.isIdle { break }
                }
            }
            #expect(await checks.commits.dropFirst(count) == [commit])
            let result = try #require(await ledger.workingState().nodes[fixture.root.id]?.requirementVerification)
            #expect(result.commit == commit && result.passed)
            #expect(await agents.calls.isEmpty)
        }
        try await verifyAndPublish(in: fixture.ledger, commit: Self.tip)
        let original = try #require(Self.single(await fixture.github.pullRequests))
        let initialEdits = await fixture.github.editedNumbers.count
        let afterCatchUp = String(repeating: "b", count: 40)
        let afterLanding = String(repeating: "c", count: 40)
        try await fixture.ledger.append([
            LedgerEvent(node: fixture.root.id, by: .adapter("Catch-up"), kind: .caughtUp(
                targetMain: "new-main", oldLandingTip: Self.tip, newLandingTip: afterCatchUp,
                method: .merge, commitMappings: [:]
            )),
        ])
        var request = fixture.request(commit: afterCatchUp)
        request.verification = nil
        await fixture.git.setTip(afterCatchUp)
        var replay = try await Self.replay(fixture.ledger)
        try await verifyAndPublish(in: replay, commit: afterCatchUp)
        let catchUpEdits = await fixture.github.editedNumbers.count
        #expect(catchUpEdits > initialEdits)
        try await replay.append([
            LedgerEvent(node: fixture.leaves[0].id, by: .reconciler, kind: .landed(commit: afterLanding)),
        ])
        let newEvidence = Self.evidence(fixture.leaves[0], check: "landing tests", commit: afterLanding)
        try await Self.record(newEvidence, on: fixture.leaves[0].id, in: replay)
        request.commit = afterLanding
        await fixture.git.setTip(afterLanding)
        replay = try await Self.replay(replay)
        let publisher = publication(in: replay)
        try await verifyAndPublish(in: replay, commit: afterLanding)
        try await publisher.reconcile([request])

        let pr = try #require(Self.single(await fixture.github.pullRequests))
        #expect(pr.number == original.number)
        #expect(pr.url == original.url)
        #expect(pr.body.contains(afterLanding))
        #expect(pr.body.contains(newEvidence.summary))
        #expect(await fixture.github.createAttempts == 1)
        #expect(await fixture.github.editedNumbers.count > catchUpEdits)
        #expect(Set(await fixture.github.editedNumbers) == Set([original.number]))
        let pushes = await fixture.git.commands
        #expect(pushes.count == 3)
        for push in pushes { try Self.expectSafePush(push, branch: fixture.branch) }
        for commit in [Self.tip, afterCatchUp, afterLanding] {
            #expect(try await Self.hasEvent(in: replay, node: fixture.root.id, values: [fixture.branch, commit]))
        }
        for commit in [afterCatchUp, afterLanding] {
            let posted = await statuses.statuses.filter { $0.commit == commit }
            #expect(posted.contains { $0.state == "pending" && $0.description == "Waiting for final verification" })
            #expect(posted.contains { $0.state == "pending" && $0.description == "Final verification running" })
            #expect(posted.contains { $0.state == "success" })
        }
        #expect(await fixture.github.unexpectedRequests.isEmpty)
    }

    @Test
    func eachPushAndTheOpenedPRHaveDurableRequirementScopedLedgerRecords() async throws {
        let fixture = try await Self.fixture()
        try await fixture.publisher().reconcile([fixture.request()])
        let pr = try #require(Self.single(await fixture.github.pullRequests))
        let replay = try await Self.replay(fixture.ledger)
        #expect(try await Self.hasEvent(in: replay, node: fixture.root.id, values: [fixture.branch, Self.tip]))
        #expect(try await Self.hasEvent(in: replay, node: fixture.root.id, values: ["\(pr.number)", pr.url]))
        #expect(await replay.verifyChain().isIntact)
        try await fixture.publisher(ledger: replay).reconcile([fixture.request()])
        #expect(await fixture.github.createAttempts == 1)
        #expect(await fixture.git.commands.count == 1)
    }

    @Test
    func differentRequirementsHaveSeparatePRsAndNeverPublishTheirLeaves() async throws {
        let fixture = try await Self.fixture()
        let ticket = await fixture.tracker.local.createTicket(
            title: "Deliver verified refund", description: "Return an accepted payment.",
            acceptanceCriteria: ["An accepted payment can be refunded."], by: .human("Reviewer")
        )
        let root = NodeSpec(
            id: "wn-\(ticket.key)", parent: nil, kind: .leaf, title: ticket.title, intent: ticket.description,
            acceptanceCriteria: ticket.acceptanceCriteria, touches: ["Refund"]
        )
        try await fixture.ledger.append([
            LedgerEvent(node: root.id, by: .human("Reviewer"), kind: .nodeCreated(spec: root, ticket: ticket.key)),
            LedgerEvent(node: root.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
            LedgerEvent(node: root.id, by: .reconciler, kind: .landed(commit: Self.tip)),
        ])
        let branch = "agentos/\(ticket.key)"
        let request = RequirementPublicationRequest(
            requirement: root.id, branch: branch, commit: Self.tip,
            verification: [Self.evidence(root, check: "full refund checks")],
            proofs: [AcceptanceCriterionProof(node: root.id, criterion: 1, tests: ["RefundTests.refundsPayment"])]
        )
        let publisher = fixture.publisher()
        try await publisher.reconcile([fixture.request(), request])
        try await publisher.reconcile([request, fixture.request()])
        let prs = await fixture.github.pullRequests
        #expect(prs.count == 2)
        #expect(Set(prs.map(\.head)) == Set([fixture.branch, branch]))
        #expect(Set(prs.map(\.number)).count == 2)
        #expect(await fixture.github.successfulCreates == 2)
        let pushes = await fixture.git.commands
        #expect(pushes.count == 2)
        for expected in [fixture.branch, branch] {
            let push = try #require(Self.single(pushes.filter {
                $0.contains { argument in
                    argument.split(separator: ":").contains { $0 == expected || $0 == "refs/heads/\(expected)" }
                }
            }))
            try Self.expectSafePush(push, branch: expected)
        }
    }

    @Test(arguments: FailurePoint.allCases)
    func publicationFailuresWaitDurablyAndOnlyAHumanRetryResumesWithoutCreatingASecondPR(
        point: FailurePoint
    ) async throws {
        let fixture = try await Self.fixture()
        var request = fixture.request()
        if point == .update {
            try await fixture.publisher().reconcile([request])
            request.commit = String(repeating: "d", count: 40)
            await fixture.git.setTip(request.commit)
        }
        if point == .push { await fixture.git.failNextPush() }
        else { await fixture.github.failNext(point) }
        try await fixture.publisher().reconcile([request])

        let comments = try #require(await fixture.tracker.local.ticket("GH-91")).comments
        #expect(comments.contains { $0.text.contains(point.message) && $0.text.contains("harness:retry") })
        let state = await fixture.ledger.workingState()
        #expect(state.attentionList.contains {
            $0.node.id == fixture.root.id && $0.reason.contains(point.message) && $0.reason.contains("harness:retry")
        })
        #expect(try await Self.hasEvent(in: fixture.ledger, node: fixture.root.id, containing: [point.message]))
        if point == .push {
            #expect(await fixture.github.mutations.isEmpty, "Opening must not continue after a failed push.")
        }
        let before = await fixture.git.commands.count
        let attempts = await fixture.github.mutations.count
        let replay = try await Self.replay(fixture.ledger)
        let restarted = fixture.publisher(ledger: replay)
        for _ in 0..<3 { try await restarted.reconcile([request]) }
        #expect(await fixture.git.commands.count == before, "Restarting/polling must not retry a failed publication.")
        #expect(await fixture.github.mutations.count == attempts)
        #expect(await replay.workingState().attentionList.contains { $0.reason.contains(point.message) })

        await fixture.tracker.local.addLabel("harness:retry", to: "GH-91", by: .human("Reviewer"))
        try await restarted.reconcile([request])
        #expect(await fixture.git.commands.count == before + 1, "An explicit retry pushes again.")
        let pr = try #require(Self.single(await fixture.github.pullRequests))
        #expect(pr.head == fixture.branch)
        #expect(await fixture.github.successfulCreates == 1, "Even a lost create response must not create another PR.")
        #expect(await fixture.github.createAttempts == (point == .open ? 2 : 1))
        #expect(await fixture.tracker.pendingSignals().isEmpty)
        #expect(!(await replay.workingState().attentionList.contains { $0.reason.contains(point.message) }))
        let records = await replay.records(for: fixture.root.id)
        #expect(!records.contains { if case .runStarted = $0.event.kind { true } else { false } },
                "Publication failures must not start agent rework.")
        #expect(await fixture.github.unexpectedRequests.isEmpty)
    }

    @MainActor @Test
    func aPushFailureIsVisibleUnderNeedsAttentionInTheWorkPane() async throws {
        let fixture = try await Self.fixture()
        let model = HarnessViewModel()
        try await fixture.ledger.append([
            LedgerEvent(node: fixture.root.id, by: .reconciler,
                        kind: .flagSet(.needsInput, reason: "Existing tracker attention")),
        ])
        model.state = await fixture.ledger.workingState()
        let control = try RenderedUI.text(of: WorkPane().environment(model), size: CGSize(width: 1200, height: 900))
        try #require(RenderedUI.shows("Needs attention", in: control))
        try #require(RenderedUI.shows("Existing tracker attention", in: control),
                     "The shared renderer must read the pre-existing Work pane before testing new behavior.")
        try await fixture.ledger.append([
            LedgerEvent(node: fixture.root.id, by: .reconciler, kind: .flagCleared(.needsInput)),
        ])
        await fixture.git.failNextPush()
        try await fixture.publisher().reconcile([fixture.request()])
        model.state = await fixture.ledger.workingState()
        let text = try RenderedUI.text(of: WorkPane().environment(model), size: CGSize(width: 1200, height: 900))
        #expect(RenderedUI.shows("Needs attention", in: text))
        #expect(RenderedUI.shows(FailurePoint.push.message, in: text))
        #expect(RenderedUI.shows("harness:retry", in: text))
    }

}
