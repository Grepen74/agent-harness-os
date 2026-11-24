// Expected API: WorkingState.appStatus(of: NodeState) -> String adds the app-only PR suffix;
// WorkingState.status(of:) remains the undecorated tracker status. WorkPane and TrackerPane
// display appStatus, and WorkPane.roots(in:showingDone:) applies the visibility toggle.
// Existing ledger PR, branch-observation, verification and run events supply all test inputs.
// Open PR tracker statuses stay In review through waiting, running, failed and passed verification;
// Queue places exclude roots with a higher-priority plain status or ineligible final verification.
// Reconciler final verification must still run for flagged roots and publication failures
// with a verification retry pending, even though their app status has no queue suffix.
// Criterion 9 (docs/real-repo-mode.md describing statuses and the toggle) is reviewer-only.
// Criteria 3-6 are the four suffix bullets following criterion 2 in the ticket.
import AgentOSAdapters
@testable import AgentOSCore
import AgentOSTestSupport
import Foundation
import SwiftUI
import Testing
@testable import AgentOSUI

@Suite
struct GH_113Tests {
    enum VerificationAttention: CaseIterable, Sendable {
        case needsInput, blocked, publicationFailureWithRetry
    }

    enum Verification: CaseIterable, Sendable {
        case waiting, verifying, verified, failed

        var suffix: String {
            switch self {
            case .waiting: "waiting for verification (1st)"
            case .verifying: "verifying"
            case .verified: "verified"
            case .failed: "verification failed"
            }
        }
    }

    @MainActor @Test
    func hidingDoneAndClosedKeepsAnOpenPullRequestWithAllLeavesProven() async throws {
        let ledger = try Ledger()
        try await Self.addRequirement(to: ledger, number: 215, verification: .verified)
        let state = await ledger.workingState()
        let root = try #require(state.nodes[Self.id(215)])
        #expect(root.phase == .proven)
        #expect(!state.requirementLeaves(for: root.id).isEmpty)
        #expect(state.requirementLeaves(for: root.id).allSatisfy { $0.phase == .proven })
        #expect(WorkPane.roots(in: state, showingDone: false).contains { $0.id == root.id })
    }

    @MainActor @Test
    func hidingDoneAndClosedOmitsMergedClosedAndDoneRequirementsEvenWithAttention() async throws {
        let ledger = try Ledger()
        try await Self.addRequirement(to: ledger, number: 215, verification: .waiting)
        try await Self.addRequirement(to: ledger, number: 216, verification: .failed)
        try await Self.addRequirement(to: ledger, number: 217, verification: .failed)
        try await Self.addRequirement(to: ledger, number: 218, verification: .verified, openPullRequest: false)
        try await ledger.append([
            Self.event(216, .requirementPullRequestMerged(number: 216, url: Self.url(216))),
            Self.event(216, .phaseChanged(to: .split)),
            Self.event(217, .requirementPullRequestClosed(number: 217, url: Self.url(217))),
            Self.event(218, .requirementMerged(commit: Self.tip(218))),
            Self.event(218, .phaseChanged(to: .split))
        ])
        let state = await ledger.workingState()
        let merged = try #require(state.nodes[Self.id(216)])
        let closed = try #require(state.nodes[Self.id(217)])
        let done = try #require(state.nodes[Self.id(218)])
        #expect(state.status(of: merged) == "Done")
        #expect(state.status(of: closed) == "Needs input")
        // A Done status hides the requirement even before its phase catches up.
        #expect(state.status(of: done) == "Done")
        #expect(state.attentionList.contains { $0.node.id == closed.id })
        let visibleIDs = WorkPane.roots(in: state, showingDone: false).map(\.id)
        #expect(visibleIDs.contains(Self.id(215)))
        for number in [216, 217, 218] {
            #expect(!visibleIDs.contains(Self.id(number)))
            #expect(WorkPane.roots(in: state, showingDone: true).contains { $0.id == Self.id(number) })
        }
    }

    @Test
    func theAppShowsVerifiedOnlyForTheCurrentRequirementTip() async throws {
        let ledger = try Ledger()
        try await Self.addRequirement(to: ledger, number: 215, verification: .verified)
        var state = await ledger.workingState()
        #expect(state.appStatus(of: try #require(state.nodes[Self.id(215)])) == "In review · #215 verified")

        try await Self.moveTip(to: "a-new-tip", number: 215, ledger: ledger)
        state = await ledger.workingState()
        #expect(state.appStatus(of: try #require(state.nodes[Self.id(215)]))
                == "In review · #215 waiting for verification (1st)")
    }

    @Test
    func waitingPlacesTrackTheQueueAndExcludeNonWaitingRequirements() async throws {
        let ledger = try Ledger()
        try await Self.addRequirement(to: ledger, number: 1, verification: .waiting, openPullRequest: false)
        for number in [5, 6, 7, 9, 10, 12, 13] {
            try await Self.addRequirement(to: ledger, number: number, verification: .waiting)
        }
        // An old ledger may record an open PR without a harness-owned published commit.
        try await Self.addRequirement(to: ledger, number: 8, verification: .waiting, openPullRequest: false)
        try await Self.addRequirement(to: ledger, number: 11, verification: .verified)
        try await ledger.append([
            Self.event(5, .phaseChanged(to: .split)),
            Self.event(6, .breakdownRevised(kept: [], dropped: ["\(Self.id(6))-leaf"])),
            LedgerEvent(node: "\(Self.id(7))-leaf", by: .reconciler, kind: .phaseChanged(to: .ready)),
            Self.event(8, .requirementPullRequestOpened(number: 8, url: Self.url(8))),
            Self.event(9, .requirementCatchUpConflicted(
                branch: "agentos/GH-9", main: "main-tip", files: ["Sources/Shared.swift"], tickets: ["GH-9"])),
            Self.event(10, .ticketClosed, by: .human("Tester")),
            Self.event(10, .phaseChanged(to: .split)),
            Self.event(11, .requirementBranchObserved(
                branch: "agentos/GH-11", tip: "unpublished-tip-11", main: "main-tip", containedInMain: false)),
            Self.event(11, .requirementPublicationFailed(error: "Push failed; fix origin then add harness:retry.")),
            Self.event(12, .flagSet(.needsInput, reason: "A person must answer before verification.")),
            Self.event(13, .flagSet(.blocked, reason: "A prerequisite must finish before verification."))
        ])
        try await Self.addRequirement(to: ledger, number: 20, verification: .verifying)
        try await Self.addRequirement(to: ledger, number: 30, verification: .verified)
        try await Self.addRequirement(to: ledger, number: 40, verification: .failed)
        try await Self.addRequirement(to: ledger, number: 50, verification: .waiting)
        try await Self.addRequirement(to: ledger, number: 60, verification: .waiting)
        try await ledger.append([
            Self.event(50, .requirementPullRequestMerged(number: 50, url: Self.url(50))),
            Self.event(60, .requirementPullRequestClosed(number: 60, url: Self.url(60)))
        ])
        // Non-waiting requirements precede these in both creation and pull-request order.
        for number in [320, 120, 220] {
            try await Self.addRequirement(to: ledger, number: number, verification: .waiting)
        }
        var state = await ledger.workingState()
        #expect(state.nodes[Self.id(5)]?.phase != .proven)
        #expect(state.requirementLeaves(for: Self.id(6)).isEmpty)
        #expect(state.requirementLeaves(for: Self.id(7)).contains { $0.phase != .proven })
        #expect(state.nodes[Self.id(8)]?.publishedCommit == nil)
        #expect(state.nodes[Self.id(9)]?.catchUpConflict != nil)
        let dependencies = UnusedDependencies()
        let reconciler = Reconciler(
            ledger: ledger, tracker: GitHubIssuesTracker(repo: GitHub.repo, transport: GitHub()),
            external: dependencies, workspace: dependencies, artifacts: dependencies, checks: dependencies,
            team: AgentTeam(name: "Queue hold only", decomposer: dependencies,
                            testAuthor: dependencies, implementer: dependencies))
        let held = try #require(state.nodes[Self.id(9)])
        #expect(held.phase == .proven)
        #expect(held.flags.isEmpty)
        #expect(state.requirementLeaves(for: held.id).allSatisfy { $0.phase == .proven })
        #expect(await reconciler.requirementIsHeld(held, in: state))
        #expect(state.nodes[Self.id(10)]?.ticketClosed == true)
        let unpublished = try #require(state.nodes[Self.id(11)])
        #expect(unpublished.publicationFailure != nil)
        #expect(unpublished.requirementVerification?.commit != unpublished.requirementBranchObservation?.tip)
        for (number, status) in [
            (9, "Needs human"), (10, "Closed"), (11, "Needs input"),
            (12, "Needs input"), (13, "Blocked")
        ] {
            let node = try #require(state.nodes[Self.id(number)])
            #expect(node.pullRequestState == .open)
            #expect(state.status(of: node) == status)
            #expect(state.appStatus(of: node) == status)
        }
        for (number, place) in [(120, "1st"), (220, "2nd"), (320, "3rd")] {
            #expect(state.appStatus(of: try #require(state.nodes[Self.id(number)]))
                    == "In review · #\(number) waiting for verification (\(place))")
        }

        try await Self.startVerification(number: 120, ledger: ledger)
        state = await ledger.workingState()
        #expect(state.appStatus(of: try #require(state.nodes[Self.id(120)])) == "In review · #120 verifying")
        #expect(state.appStatus(of: try #require(state.nodes[Self.id(220)]))
                == "In review · #220 waiting for verification (1st)")
        #expect(state.appStatus(of: try #require(state.nodes[Self.id(320)]))
                == "In review · #320 waiting for verification (2nd)")
    }

    @Test
    func anOpenPullRequestShowsVerifyingWhileFinalVerificationIsRunning() async throws {
        let ledger = try Ledger()
        try await Self.addRequirement(to: ledger, number: 215, verification: .verifying)
        let state = await ledger.workingState()
        #expect(state.appStatus(of: try #require(state.nodes[Self.id(215)])) == "In review · #215 verifying")
    }

    @Test(arguments: VerificationAttention.allCases)
    func finalVerificationStillChecksOpenPullRequestsWithFlagsOrAPublicationFailureRetry(
        attention: VerificationAttention
    ) async throws {
        let ledger = try Ledger()
        let tracker = LocalTracker(store: nil)
        let ticket = await tracker.createTicket(
            title: "Requirement 215", description: "Verify the current tip", acceptanceCriteria: ["Works"],
            by: .human("Tester"))
        try await Self.addRequirement(to: ledger, number: 215, verification: .verified, ticket: ticket.key)
        let tip = "unverified-tip-with-attention"
        try await ledger.append([Self.event(215, .requirementBranchObserved(
            branch: "agentos/\(ticket.key)", tip: tip, main: "main-tip", containedInMain: false))])
        switch attention {
        case .needsInput:
            try await ledger.append([Self.event(215, .flagSet(.needsInput, reason: "Answer needed"))])
        case .blocked:
            try await ledger.append([Self.event(215, .flagSet(.blocked, reason: "Prerequisite needed"))])
        case .publicationFailureWithRetry:
            try await ledger.append([
                Self.event(215, .requirementPublicationFailed(error: "Push failed")),
                Self.event(215, .requirementVerificationRetryRequested, by: .human("Tester"))
            ])
        }
        let before = await ledger.workingState()
        let root = try #require(before.nodes[Self.id(215)])
        #expect(root.pullRequestState == .open)
        #expect(root.requirementVerification?.commit != tip)
        if attention == .publicationFailureWithRetry {
            #expect(root.publicationFailure != nil && root.requirementVerificationRetryPending)
            #expect(!root.publicationRetryPending)
        } else {
            #expect(!root.flags.isEmpty)
        }
        let workspace = VerificationWorkspace(tip: tip)
        let verification = RecordingVerification()
        let unused = UnusedDependencies()
        let reconciler = Reconciler(
            ledger: ledger, tracker: LocalTrackerAdapter(tracker: tracker), external: unused,
            workspace: workspace, artifacts: VerificationArtifacts(), checks: verification,
            team: AgentTeam(name: "Final verification only", decomposer: unused,
                            testAuthor: unused, implementer: unused),
            policy: Policy(pullRequests: true), publisher: verification)
        try await withHangGuard("GH-113 final verification with attention") {
            var report = RoundReport()
            try await reconciler.verifyCompletedRequirements(&report)
        }
        #expect(await verification.checkedSuites.count == 1)
        #expect(await verification.checkedSuites.allSatisfy { $0 == nil })
        let result = try #require(await ledger.workingState().nodes[root.id]?.requirementVerification)
        #expect(result.commit == tip)
        #expect(result.passed)
        #expect(await tracker.ticket(ticket.key)?.comments.contains {
            $0.text.contains("Final verification passed at \(tip)")
        } == true)
    }

    @Test
    func aFailedCurrentTipShowsVerificationFailedRatherThanDoneOrNeedsInput() async throws {
        let ledger = try Ledger()
        try await Self.addRequirement(to: ledger, number: 215, verification: .failed)
        var state = await ledger.workingState()
        #expect(state.attentionList.contains { $0.node.id == Self.id(215) })
        #expect(state.appStatus(of: try #require(state.nodes[Self.id(215)]))
                == "In review · #215 verification failed")

        try await Self.moveTip(to: "fixed-tip", number: 215, ledger: ledger)
        state = await ledger.workingState()
        #expect(state.appStatus(of: try #require(state.nodes[Self.id(215)]))
                == "In review · #215 waiting for verification (1st)")
    }

    @Test(arguments: Verification.allCases)
    func anOpenPullRequestKeepsItsTrackerStatusInReviewDuringVerification(
        verification: Verification
    ) async throws {
        let ledger = try Ledger()
        try await Self.addRequirement(to: ledger, number: 215, verification: verification)
        let state = await ledger.workingState()
        let node = try #require(state.nodes[Self.id(215)])
        #expect(node.pullRequestState == .open)
        #expect(state.status(of: node) == "In review")
    }

    @MainActor @Test
    func theSharedRendererReadsAnExistingWorkTreeRowAndTrackerStatus() async throws {
        let ledger = try Ledger()
        try await Self.addRequirement(to: ledger, number: 215, verification: .waiting)
        let model = Self.model(for: await ledger.workingState())
        let node = try #require(model.state.nodes[Self.id(215)])
        let sample = try RenderedUI.text(
            of: NodeRow(node: node, status: "In review · #215 waiting for verification (1st)"),
            size: CGSize(width: 900, height: 100))
        #expect(RenderedUI.shows("#215", in: sample), "\(sample)")
        #expect(RenderedUI.shows("waiting for verification (1st)", in: sample), "\(sample)")
        for text in [
            try RenderedUI.text(of: WorkPane().environment(model), size: CGSize(width: 2200, height: 900)),
            try RenderedUI.text(of: TrackerPane().environment(model), size: CGSize(width: 2200, height: 900))
        ] {
            #expect(RenderedUI.shows("Requirement 215", in: text), "\(text)")
            #expect(RenderedUI.shows("In review", in: text), "\(text)")
            #expect(RenderedUI.shows("#215", in: text), "\(text)")
            #expect(RenderedUI.shows("waiting for verification (1st)", in: text), "\(text)")
        }
    }

    @MainActor @Test(arguments: Verification.allCases)
    func bothWorkTreeAndTrackerRenderTheOpenPullRequestAndItsVerification(
        verification: Verification
    ) async throws {
        let ledger = try Ledger()
        if verification == .waiting {
            try await Self.addRequirement(to: ledger, number: 120, verification: .waiting)
        }
        try await Self.addRequirement(
            to: ledger, number: 215, verification: verification,
            ticket: "GH-900", title: "Checkout")
        let state = await ledger.workingState()
        let node = try #require(state.nodes[Self.id(215)])
        let model = Self.model(for: state)
        let suffix = verification == .waiting ? "waiting for verification (2nd)" : verification.suffix
        #expect(state.appStatus(of: node) == "In review · #215 \(suffix)")
        let workTree = try RenderedUI.text(
            of: WorkPane().environment(model), size: CGSize(width: 2200, height: 900))
        let tracker = try RenderedUI.text(
            of: TrackerPane().environment(model), size: CGSize(width: 2200, height: 900))
        for text in [workTree, tracker] {
            #expect(RenderedUI.shows("In review", in: text), "\(text)")
            #expect(RenderedUI.shows("Checkout", in: text), "\(text)")
            #expect(RenderedUI.shows("#215", in: text), "\(text)")
            #expect(RenderedUI.shows(suffix, in: text), "\(text)")
        }
    }

    @MainActor @Test
    func theTrackerUsesWorkingStateForAnOpenPullRequestWhenTicketStatusIsStale() async throws {
        let ledger = try Ledger()
        try await Self.addRequirement(
            to: ledger, number: 215, verification: .verified,
            ticket: "GH-900", title: "Checkout")
        let state = await ledger.workingState()
        let model = Self.model(for: state)
        model.tickets[0].status = "Ready"
        #expect(state.appStatus(of: try #require(state.nodes[Self.id(215)])) == "In review · #215 verified")
        let text = try RenderedUI.text(
            of: TrackerPane().environment(model), size: CGSize(width: 2200, height: 900))
        #expect(RenderedUI.shows("Checkout", in: text), "\(text)")
        #expect(RenderedUI.shows("In review", in: text), "\(text)")
        #expect(RenderedUI.shows("#215", in: text), "\(text)")
        #expect(RenderedUI.shows("verified", in: text), "\(text)")
        #expect(!RenderedUI.shows("Ready", in: text), "\(text)")
    }

    @MainActor @Test(arguments: [RequirementPullRequest.State.merged, .closed])
    func mergedOrClosedPullRequestsShowTheirPlainStatusInBothPanes(
        pullRequestState: RequirementPullRequest.State
    ) async throws {
        let ledger = try Ledger()
        try await Self.addRequirement(to: ledger, number: 215, verification: .verified)
        let kind: EventKind = pullRequestState == .merged
            ? .requirementPullRequestMerged(number: 215, url: Self.url(215))
            : .requirementPullRequestClosed(number: 215, url: Self.url(215))
        try await ledger.append([Self.event(215, kind)])
        let state = await ledger.workingState()
        let status = pullRequestState == .merged ? "Done" : "Needs input"
        #expect(state.status(of: try #require(state.nodes[Self.id(215)])) == status)
        #expect(state.appStatus(of: try #require(state.nodes[Self.id(215)])) == status)
        let model = Self.model(for: state)
        let size = CGSize(width: 1500, height: 900)
        // Both toggles start off: the work tree hides the requirement, the tracker only a Done ticket.
        let hiddenWorkTree = try RenderedUI.text(of: WorkPane().environment(model), size: size)
        #expect(!RenderedUI.shows("Requirement 215", in: hiddenWorkTree), "\(hiddenWorkTree)")
        let hiddenTracker = try RenderedUI.text(of: TrackerPane().environment(model), size: size)
        #expect(RenderedUI.shows("Requirement 215", in: hiddenTracker) == (pullRequestState == .closed),
                "\(hiddenTracker)")
        for pane in [AnyView(WorkPane(showingDone: true)), AnyView(TrackerPane(showingDone: true))] {
            let row = try Self.rowText("Requirement 215", in: RenderedUI.image(of: pane.environment(model), size: size))
            #expect(RenderedUI.shows(status, in: row), "\(row)")
            #expect(!RenderedUI.shows("#215", in: row), "\(row)")
        }
    }

    /// The text on the rendered row whose title is `title`, left to right.
    @MainActor private static func rowText(_ title: String, in image: CGImage) throws -> String {
        let lines = try RenderedUI.lines(in: image)
        let row = try #require(lines.first { RenderedUI.shows(title, in: $0.text) },
                               "No row \(title) in \(lines.map(\.text))")
        return lines.filter { abs($0.box.midY - row.box.midY) < row.box.height / 2 }
            .sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
    }

    @Test(arguments: [false, true])
    func verificationTransitionsLeaveTicketLabelsAndTheProjectsBoardInReview(
        hasProject: Bool
    ) async throws {
        let ledger = try Ledger()
        try await Self.addRequirement(to: ledger, number: 215, verification: .waiting)
        let github = GitHub()
        let tracker = GitHubIssuesTracker(
            repo: GitHub.repo, transport: github,
            project: hasProject ? .init(owner: "owner", number: 7) : nil,
            listInterval: .zero)
        let dependencies = UnusedDependencies()
        let reconciler = Reconciler(
            ledger: ledger, tracker: tracker, external: dependencies,
            workspace: dependencies, artifacts: dependencies, checks: dependencies,
            team: AgentTeam(name: "Status projection only", decomposer: dependencies,
                            testAuthor: dependencies, implementer: dependencies))
        for verification in [Verification.waiting, .verifying, .failed, .verified] {
            if verification == .verifying {
                try await Self.startVerification(number: 215, ledger: ledger)
            } else if verification == .failed || verification == .verified {
                if verification == .verified {
                    try await Self.startVerification(number: 215, ledger: ledger)
                }
                try await Self.finishVerification(
                    number: 215, passed: verification == .verified, ledger: ledger)
            }
            let state = await ledger.workingState()
            #expect(state.status(of: try #require(state.nodes[Self.id(215)])) == "In review")
            await reconciler.projectStatuses()
            #expect(await tracker.ticket("GH-215")?.status == "In review")
            #expect(await github.statusLabels == ["agentos: In review"])
            if hasProject {
                #expect(await github.boardStatus == "In review")
            } else {
                #expect(await github.boardWrites.isEmpty)
            }
            #expect(await tracker.takeProblems().isEmpty)
        }
        #expect(await github.labelWrites == ["agentos: In review"])
        if hasProject {
            #expect(await github.boardWrites == ["In review"])
        }
    }

    private static func id(_ number: Int) -> NodeID { "wn-GH-\(1000 - number)" }
    private static func tip(_ number: Int) -> String { "tip-\(number)" }
    private static func url(_ number: Int) -> String { "https://github.com/owner/project/pull/\(number)" }
    private static func run(_ number: Int) -> RunID { "verification-\(number)" }

    private static func event(
        _ number: Int, _ kind: EventKind, by: Participant = .reconciler
    ) -> LedgerEvent {
        LedgerEvent(node: Self.id(number), by: by, kind: kind,
                    at: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private static func addRequirement(
        to ledger: Ledger, number: Int, verification: Verification, openPullRequest: Bool = true,
        ticket: String? = nil, title: String? = nil
    ) async throws {
        let ticket = ticket ?? "GH-\(number)"
        let root = NodeSpec(id: Self.id(number), kind: .composite, title: title ?? "Requirement \(number)",
                            intent: "Verify the completed requirement", acceptanceCriteria: ["Works"])
        let leaf = NodeSpec(id: "\(root.id)-leaf", parent: root.id, kind: .leaf,
                            title: "Completed leaf", intent: "Part of requirement", acceptanceCriteria: ["Works"])
        try await ledger.append([
            Self.event(number, .nodeCreated(spec: root, ticket: ticket)),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .nodeCreated(spec: leaf, ticket: "LEAF-\(number)")),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .landed(commit: Self.tip(number))),
            LedgerEvent(node: leaf.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
            Self.event(number, .phaseChanged(to: .proven)),
            Self.event(number, .requirementBranchObserved(
                branch: "agentos/\(ticket)", tip: Self.tip(number), main: "main-tip", containedInMain: false))
        ])
        if openPullRequest {
            try await ledger.append([
                Self.event(number, .requirementPushed(branch: "agentos/\(ticket)", commit: Self.tip(number))),
                Self.event(number, .requirementPublicationFinished(commit: Self.tip(number))),
                Self.event(number, .requirementPullRequestOpened(number: number, url: Self.url(number)))
            ])
        }
        if verification != .waiting {
            try await Self.startVerification(number: number, ledger: ledger)
            if verification != .verifying {
                try await Self.finishVerification(number: number, passed: verification == .verified, ledger: ledger)
            }
        }
    }

    private static func startVerification(number: Int, ledger: Ledger) async throws {
        try await ledger.append([
            Self.event(number, .requirementVerificationStarted),
            Self.event(number, .runStarted(run: Self.run(number), role: .verifier))
        ])
    }

    private static func finishVerification(number: Int, passed: Bool, ledger: Ledger) async throws {
        let state = await ledger.workingState()
        let node = try #require(state.nodes[Self.id(number)])
        let evidence = Evidence(
            check: "final requirement verification", passed: passed,
            summary: passed ? "Full checks passed" : "Acceptance check failed",
            specHash: node.spec.specHash, builtBy: "builder-\(number)", checkedBy: Self.run(number),
            artifactPath: "verification-\(number).log", artifactSHA256: "test-artifact",
            commit: try #require(node.requirementBranchObservation?.tip))
        try await ledger.append([
            Self.event(number, .requirementVerificationFinished(evidence),
                       by: .agent(run: Self.run(number), role: .verifier)),
            Self.event(number, .runFinished(run: Self.run(number), outcome: passed ? "passed" : "failed"))
        ])
    }

    private static func moveTip(to tip: String, number: Int, ledger: Ledger) async throws {
        try await ledger.append([
            Self.event(number, .requirementBranchObserved(
                branch: "agentos/GH-\(number)", tip: tip, main: "new-main", containedInMain: false)),
            Self.event(number, .requirementPushed(branch: "agentos/GH-\(number)", commit: tip)),
            Self.event(number, .requirementPublicationFinished(commit: tip))
        ])
    }

    @MainActor private static func model(for state: WorkingState) -> HarnessViewModel {
        let model = HarnessViewModel()
        model.state = state
        model.tickets = state.roots.map { node in
            var ticket = Ticket(key: node.ticket, title: node.spec.title, description: "",
                                acceptanceCriteria: node.spec.acceptanceCriteria, createdBy: .human("Tester"))
            ticket.status = state.status(of: node)
            return ticket
        }
        return model
    }
}
