// API contract: HarnessViewModel.pullRequestDetails(for:) -> PullRequestDetails? projects
// ledger-backed PR number/URL, pushed commit/status, last verified commit/result,
// latest-main containment, catch-up commit/time and verification queue position.
// WorkingState.verificationQueue supplies the same ordered requirements to RunningAgents
// and NodeDetail. VerificationCommitStatus and the status/containment observation events
// named in .agentos-report.json supply facts not present in the existing ledger API.
// Existing NodeDetail and RunningAgents must render these facts, including an actionable link.
// EventKind.requirementVerificationStatusPosted(commit: String, state: VerificationCommitStatus)
// records a posted pending/success/failure for that exact commit; later events for another
// commit must not overwrite the last pushed commit's status.
// EventKind.requirementBranchContainmentObserved(branch: String, tip: String, main: String,
// containsMain: Bool) records the reverse ancestry fact (main is in branch, not branch in main).
// PullRequestDetails exposes number: Int, url: URL, pushedCommit/verifiedCommit/catchUpMain:
// String?, status: VerificationCommitStatus?, verificationPassed/containsLatestMain: Bool?,
// caughtUpAt: Date?, queuePosition: Int? (one-based; nil when not waiting).
// Preserve the last completed verification while a new one runs. Catch-up time is the
// node's latest catchUpSucceeded event time. The queue is [NodeState]; these UI tests
// follow its order, not an independently chosen PR-number or creation-order rule.
// Queue places are one-based numbers; no ordinal wording or locale is prescribed.
// Labelled fields associate each value with its meaning, using NodeDetail's grid convention.
// Reviewer-only AC10-13: real-repo-mode.md describes the details and queue, default-branch
// protection/ruleset requiring agentos/verified and up-to-date branches, its gh api setup
// command, and admin bypass. Documentation is not tested by reading source text.

import AgentOSCore
import AgentOSTestSupport
@testable import AgentOSUI
import AppKit
import Foundation
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct GH_114Tests {
    private static let pushed = String(repeating: "facecafe", count: 5)
    private static let verified = String(repeating: "deadbeef", count: 5)
    private static let main = String(repeating: "abcdfeed", count: 5)
    private static let oldMain = String(repeating: "beadbead", count: 5)
    private static let firstCatchUp = Date(timeIntervalSince1970: 1_800_000_000)
    private static let latestCatchUp = Date(timeIntervalSince1970: 1_800_086_400)

    private static func checkUIHelpers() async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-PROBE")
        let text = try Self.detailText(fixture.model, id: id)
        #expect(RenderedUI.shows("GH-PROBE", in: text))
        #expect(RenderedUI.shows("Phase", in: text))
        let phaseRow = try Self.detailRowText(fixture.model, id: id, label: "Phase")
        #expect(RenderedUI.shows("proven", in: phaseRow))
        #expect(RenderedUI.shows("inherited", in: text))
        #expect(!RenderedUI.shows("inherited", in: phaseRow))
        let queueImage = try RenderedUI.image(
            of: HStack { Text("Probe queue"); Text("Position 1") },
            size: CGSize(width: 400, height: 60))
        let queueRow = try Self.rowText("Probe queue", lines: RenderedUI.lines(in: queueImage))
        #expect(Self.showsQueuePlace(1, in: queueRow))
        for wording in ["#1", "1 of 3", "1st"] {
            #expect(Self.showsQueuePlace(1, in: wording))
        }
        #expect(!Self.showsQueuePlace(1, in: "GH-WAITING #74 Existing list", pullRequest: 74))
        #expect(!Self.showsQueuePlace(3, in: "2 of 3"))
        try await fixture.finishVerification(id, commit: Self.verified, passed: true)
        #expect(fixture.model.state.nodes[id]?.requirementVerification?.passed == true)
        #expect(fixture.model.state.nodes[id]?.activeRun == nil)
        try await fixture.record(id, [.runStarted(run: "probe-run", role: .verifier)])
        let runningImage = try RenderedUI.image(of: RunningAgents().environment(fixture.model),
                                                size: CGSize(width: 1_400, height: 600))
        #expect(try Self.rowY("GH-PROBE", lines: RenderedUI.lines(in: runningImage)) > 0)

        let destination = try #require(URL(string: "https://example.invalid/probe"))
        let opened = OpenedURLs()
        let host = Self.actionableHost(Link("Probe link", destination: destination), opened: opened)
        let image = try RenderedUI.image(of: host)
        #expect(RenderedUI.shows("Probe link", in: try RenderedUI.text(in: image).joined(separator: "\n")))
        try Self.press("Probe link", in: host)
        #expect(opened.values == [destination])
    }

    @Test
    func aRequirementWithAPullRequestHasAPullRequestDetailsSection() async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-DETAIL", pullRequest: 74)
        #expect(RenderedUI.shows("Pull request", in: try Self.detailText(fixture.model, id: id)))
    }

    @Test
    func thePullRequestNumberIsALinkThatOpensItsRecordedURL() async throws {
        try await Self.checkUIHelpers()
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-LINK", pullRequest: 74)
        let details = try #require(fixture.model.pullRequestDetails(for: id))
        #expect(details.number == 74)
        #expect(details.url.absoluteString == Fixture.url(74))
        let node = try #require(fixture.model.state.nodes[id])
        let opened = OpenedURLs()
        let host = Self.actionableHost(NodeDetail(node: node).environment(fixture.model), opened: opened)
        let text = try RenderedUI.text(in: RenderedUI.image(of: host)).joined(separator: "\n")
        #expect(RenderedUI.shows("#74", in: text))
        try Self.press("#74", in: host)
        #expect(opened.values == [details.url])
    }

    @Test(arguments: [
        (VerificationCommitStatus.pending, "Pending"),
        (VerificationCommitStatus.success, "Success"),
        (VerificationCommitStatus.failure, "Failure"),
    ])
    func detailsShowTheLastPushedCommitAndItsPostedStatus(status: VerificationCommitStatus, wording: String) async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-STATUS", pullRequest: 74)
        try await fixture.finishVerification(id, commit: Self.verified, passed: status != .success)
        try await fixture.record(id, [
            .requirementPushed(branch: Fixture.branch("GH-STATUS"), commit: Self.pushed),
            .requirementVerificationStatusPosted(commit: Self.pushed, state: status),
        ])
        let details = try #require(fixture.model.pullRequestDetails(for: id))
        #expect(details.pushedCommit == Self.pushed)
        #expect(details.status == status)
        let commitRow = try Self.detailRowText(fixture.model, id: id, label: "Last pushed commit")
        let statusRow = try Self.detailRowText(fixture.model, id: id, label: "agentos/verified")
        #expect(RenderedUI.shows(String(Self.pushed.prefix(8)), in: commitRow))
        #expect(RenderedUI.shows(wording, in: statusRow))
    }

    @Test
    func aPushedCommitWithNoPostedStatusSaysNotPostedEvenWhenVerificationPassed() async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-UNPOSTED", pullRequest: 74)
        try await fixture.finishVerification(id, commit: Self.pushed, passed: true)
        try await fixture.record(id, [.requirementPushed(branch: Fixture.branch("GH-UNPOSTED"), commit: Self.pushed)])
        let details = try #require(fixture.model.pullRequestDetails(for: id))
        #expect(details.pushedCommit == Self.pushed)
        #expect(details.status == nil)
        #expect(RenderedUI.shows("Not posted", in: try Self.detailRowText(fixture.model, id: id, label: "agentos/verified")))
    }

    @Test
    func aStatusForAnOlderCommitIsNotShownAsTheLastPushedCommitsStatus() async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-NEW-TIP", pullRequest: 74)
        try await fixture.record(id, [
            .requirementPushed(branch: Fixture.branch("GH-NEW-TIP"), commit: Self.verified),
            .requirementVerificationStatusPosted(commit: Self.verified, state: .success),
            .requirementPushed(branch: Fixture.branch("GH-NEW-TIP"), commit: Self.pushed),
            .requirementVerificationStatusPosted(commit: Self.pushed, state: .pending),
            .requirementVerificationStatusPosted(commit: Self.verified, state: .failure),
        ])
        let details = try #require(fixture.model.pullRequestDetails(for: id))
        #expect(details.pushedCommit == Self.pushed)
        #expect(details.status == .pending)
        #expect(RenderedUI.shows("Pending", in: try Self.detailRowText(fixture.model, id: id, label: "agentos/verified")))
    }

    @Test(arguments: [true, false])
    func detailsKeepTheLastVerifiedCommitAndWhetherItPassedSeparateFromThePushedTip(passed: Bool) async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-RESULT", pullRequest: 74)
        try await fixture.finishVerification(id, commit: Self.verified, passed: passed)
        try await fixture.record(id, [.requirementPushed(branch: Fixture.branch("GH-RESULT"), commit: Self.pushed)])
        let details = try #require(fixture.model.pullRequestDetails(for: id))
        #expect(details.verifiedCommit == Self.verified)
        #expect(details.verificationPassed == passed)
        #expect(details.pushedCommit == Self.pushed)
        let text = try Self.detailRowText(fixture.model, id: id, label: "Last verified commit")
        #expect(RenderedUI.shows(String(Self.verified.prefix(8)), in: text))
        #expect(RenderedUI.shows(passed ? "Passed" : "Failed", in: text))
    }

    @Test
    func startingANewVerificationDoesNotEraseTheLastCompletedVerificationFromDetails() async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-REVERIFY", pullRequest: 74)
        try await fixture.finishVerification(id, commit: Self.verified, passed: false)
        try await fixture.record(id, [
            .requirementPushed(branch: Fixture.branch("GH-REVERIFY"), commit: Self.pushed),
            .requirementVerificationStarted,
            .runStarted(run: "current-verification", role: .verifier),
        ])
        let details = try #require(fixture.model.pullRequestDetails(for: id))
        #expect(details.verifiedCommit == Self.verified)
        #expect(details.verificationPassed == false)
        let text = try Self.detailRowText(fixture.model, id: id, label: "Last verified commit")
        #expect(RenderedUI.shows(String(Self.verified.prefix(8)), in: text))
        #expect(RenderedUI.shows("Failed", in: text))
    }

    @Test(arguments: [true, false])
    func detailsSayWhetherTheRequirementBranchContainsTheLatestFetchedMain(containsMain: Bool) async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-CONTAINS", pullRequest: 74)
        try await fixture.baseline(Self.main)
        try await fixture.record(id, [
            .requirementBranchContainmentObserved(
                branch: Fixture.branch("GH-CONTAINS"), tip: Self.pushed,
                main: Self.main, containsMain: containsMain),
        ])
        let details = try #require(fixture.model.pullRequestDetails(for: id))
        #expect(details.containsLatestMain == containsMain)
        let text = try Self.detailRowText(fixture.model, id: id, label: "Contains latest main")
        #expect(RenderedUI.shows(containsMain ? "Yes" : "No", in: text))
    }

    @Test
    func anOlderCatchUpDoesNotClaimTheBranchContainsANewerFetchedMain() async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-STALE", pullRequest: 74)
        try await fixture.baseline(Self.oldMain)
        try await fixture.record(id, [
            .catchUpSucceeded(main: Self.oldMain, newAgentOSMainTip: Self.pushed, method: .automatic),
            .requirementBranchContainmentObserved(
                branch: Fixture.branch("GH-STALE"), tip: Self.pushed,
                main: Self.oldMain, containsMain: true),
        ], at: Self.firstCatchUp)
        try await fixture.baseline(Self.main)
        try await fixture.record(id, [
            .requirementBranchContainmentObserved(
                branch: Fixture.branch("GH-STALE"), tip: Self.pushed,
                main: Self.main, containsMain: false),
        ])
        let details = try #require(fixture.model.pullRequestDetails(for: id))
        #expect(details.containsLatestMain == false)
        #expect(details.catchUpMain == Self.oldMain)
        #expect(RenderedUI.shows("No", in: try Self.detailRowText(fixture.model, id: id, label: "Contains latest main")))
    }

    @Test
    func detailsShowTheRequirementsLatestCatchUpMainAndRecordedTime() async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-CATCHUP", pullRequest: 74)
        try await fixture.record(id, [
            .catchUpSucceeded(main: Self.oldMain, newAgentOSMainTip: Self.verified, method: .automatic),
        ], at: Self.firstCatchUp)
        try await fixture.record(id, [
            .catchUpSucceeded(main: Self.main, newAgentOSMainTip: Self.pushed, method: .manual),
        ], at: Self.latestCatchUp)
        let other = try await fixture.requirement("GH-OTHER")
        try await fixture.record(other, [
            .catchUpSucceeded(main: "other-main", newAgentOSMainTip: "other-tip", method: .automatic),
        ], at: Self.latestCatchUp.addingTimeInterval(60))
        let details = try #require(fixture.model.pullRequestDetails(for: id))
        #expect(details.catchUpMain == Self.main)
        #expect(details.caughtUpAt == Self.latestCatchUp)
        let text = try Self.detailRowText(fixture.model, id: id, label: "Last catch-up")
        #expect(RenderedUI.shows(String(Self.main.prefix(8)), in: text))
        let time = Self.latestCatchUp.formatted(Date.FormatStyle(
            date: .numeric, time: .standard, locale: .current, timeZone: .current))
        #expect(RenderedUI.shows(time, in: text))
    }

    @Test
    func detailsShowTheSameQueuePlaceAsTheVerificationQueue() async throws {
        let fixture = try Fixture()
        let later = try await fixture.requirement("GH-LATER", pullRequest: 94)
        let earlier = try await fixture.requirement("GH-EARLIER", pullRequest: 74)
        let queue = fixture.model.state.verificationQueue.map(\.id)
        #expect(queue.contains(earlier))
        let position = try #require(queue.firstIndex(of: later)) + 1
        let details = try #require(fixture.model.pullRequestDetails(for: later))
        #expect(details.queuePosition == position)
        #expect(Self.showsQueuePlace(position,
                                    in: try Self.detailRowText(fixture.model, id: later, label: "Verification queue")))
    }

    @Test(arguments: [false, true])
    func aVerifiedOrCurrentlyVerifyingPullRequestSaysItIsNotWaiting(running: Bool) async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-NOT-WAITING", pullRequest: 74)
        try await fixture.record(id, [.requirementPushed(branch: Fixture.branch("GH-NOT-WAITING"), commit: Self.pushed)])
        if running {
            try await fixture.record(id, [
                .requirementVerificationStarted, .runStarted(run: "verification", role: .verifier),
            ])
        } else {
            try await fixture.finishVerification(id, commit: Self.pushed, passed: true)
        }
        let details = try #require(fixture.model.pullRequestDetails(for: id))
        #expect(details.queuePosition == nil)
        #expect(RenderedUI.shows("Not waiting", in: try Self.detailRowText(fixture.model, id: id, label: "Verification queue")))
    }

    @Test
    func aRequirementWithoutAPullRequestHasNoPullRequestDetailsSection() async throws {
        let fixture = try Fixture()
        let id = try await fixture.requirement("GH-LOCAL")
        try await fixture.finishVerification(id, commit: Self.verified, passed: true)
        try await fixture.record(id, [.requirementPushed(branch: Fixture.branch("GH-LOCAL"), commit: Self.pushed)])
        #expect(fixture.model.pullRequestDetails(for: id) == nil)
        let text = try Self.detailText(fixture.model, id: id)
        #expect(RenderedUI.shows("GH-LOCAL", in: text))
        #expect(!RenderedUI.shows("Pull request", in: text))
    }

    @Test
    func runningAgentsShowsWaitingTicketsPRNumbersAndPlacesBelowRunningWorkInQueueOrder() async throws {
        let fixture = try Fixture()
        let later = try await fixture.requirement("GH-LATER", pullRequest: 94)
        let earlier = try await fixture.requirement("GH-EARLIER", pullRequest: 74)
        let unpublished = try await fixture.requirement("GH-UNPUBLISHED")
        let running = try await fixture.requirement("GH-ACTIVE", pullRequest: 64)
        try await fixture.record(running, [
            .requirementVerificationStarted, .runStarted(run: "running-check", role: .verifier),
        ])
        let verified = try await fixture.requirement("GH-VERIFIED", pullRequest: 54)
        try await fixture.finishVerification(verified, commit: Self.pushed, passed: true)
        let closed = try await fixture.requirement("GH-CLOSED", pullRequest: 44)
        try await fixture.record(closed, [.requirementPullRequestClosed(number: 44, url: Fixture.url(44))])
        let queue = fixture.model.state.verificationQueue
        #expect(queue.contains { $0.id == earlier })
        #expect(queue.contains { $0.id == later })
        #expect(queue.contains { $0.id == unpublished })
        #expect(!queue.contains { [running, verified, closed].contains($0.id) })

        let image = try RenderedUI.image(of: RunningAgents().environment(fixture.model),
                                         size: CGSize(width: 1_400, height: 600))
        let lines = try RenderedUI.lines(in: image)
        let text = lines.map(\.text).joined(separator: "\n")
        #expect(RenderedUI.shows("Running now", in: text))
        #expect(RenderedUI.shows("Waiting for final verification", in: text))
        #expect(RenderedUI.shows("#74", in: text))
        #expect(RenderedUI.shows("#94", in: text))
        var precedingY = try Self.rowY("GH-ACTIVE", lines: lines)
        for (index, node) in queue.enumerated() {
            let ticket = node.ticket
            let rowText = try Self.rowText(ticket, lines: lines)
            #expect(Self.showsQueuePlace(index + 1, in: rowText, pullRequest: node.pullRequestNumber),
                    "\(ticket) must show its queue place")
            if let number = node.pullRequestNumber {
                #expect(RenderedUI.shows("#\(number)", in: rowText), "\(ticket) must show its own pull request")
            }
            let y = try Self.rowY(ticket, lines: lines)
            #expect(precedingY > y, "\(ticket) must follow the preceding running or queued row")
            precedingY = y
        }
        #expect(!RenderedUI.shows("GH-VERIFIED", in: text))
        #expect(!RenderedUI.shows("GH-CLOSED", in: text))
    }

    @Test
    func theVerificationQueueIsVisibleEvenWhenNoAgentIsRunning() async throws {
        let fixture = try Fixture()
        _ = try await fixture.requirement("GH-WAITING", pullRequest: 74)
        #expect(fixture.model.state.running.isEmpty)
        let image = try RenderedUI.image(of: RunningAgents().environment(fixture.model),
                                        size: CGSize(width: 1_400, height: 400))
        let lines = try RenderedUI.lines(in: image)
        let text = lines.map(\.text).joined(separator: "\n")
        #expect(RenderedUI.shows("Waiting for final verification", in: text))
        let rowText = try Self.rowText("GH-WAITING", lines: lines)
        #expect(RenderedUI.shows("#74", in: rowText))
        #expect(Self.showsQueuePlace(1, in: rowText, pullRequest: 74))
    }

    private static func showsQueuePlace(_ position: Int, in text: String, pullRequest: Int? = nil) -> Bool {
        let placeText = pullRequest.map {
            text.replacingOccurrences(of: "#\\s*\($0)\\b", with: "", options: .regularExpression)
        } ?? text
        guard let digits = placeText.range(of: "[0-9]+", options: .regularExpression) else { return false }
        return Int(placeText[digits]) == position
    }

    private static func detailRowText(_ model: HarnessViewModel, id: NodeID, label: String) throws -> String {
        let node = try #require(model.state.nodes[id])
        let image = try RenderedUI.image(of: NodeDetail(node: node).environment(model)
            .environment(\.locale, .current).environment(\.timeZone, .current),
            size: CGSize(width: 1_400, height: 1_000))
        return try Self.rowText(label, lines: RenderedUI.lines(in: image))
    }

    private static func rowText(_ label: String, lines: [RenderedUI.Line]) throws -> String {
        let row = try #require(lines.first { RenderedUI.shows(label, in: $0.text) },
                               "Missing labelled row \(label)")
        return lines.filter { abs($0.box.midY - row.box.midY) < row.box.height / 2 }
            .sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
    }

    private static func detailText(_ model: HarnessViewModel, id: NodeID) throws -> String {
        let node = try #require(model.state.nodes[id])
        return try RenderedUI.text(of: NodeDetail(node: node).environment(model)
            .environment(\.locale, .current).environment(\.timeZone, .current),
            size: CGSize(width: 1_400, height: 1_000))
    }

    private static func rowY(_ ticket: String, lines: [RenderedUI.Line]) throws -> CGFloat {
        try #require(lines.first { RenderedUI.shows(ticket, in: $0.text) }).box.midY
    }

    @MainActor
    private final class Fixture {
        let ledger: Ledger
        let model = HarnessViewModel()

        init() throws { ledger = try Ledger() }

        static func branch(_ ticket: String) -> String { "agentos/\(ticket)" }
        static func url(_ number: Int) -> String { "https://github.com/example/project/pull/\(number)" }

        func requirement(_ ticket: String, pullRequest: Int? = nil) async throws -> NodeID {
            let id = "wn-\(ticket)"
            let spec = NodeSpec(id: id, parent: nil, kind: .composite, title: "Requirement \(ticket)",
                                intent: "Review current verification facts", acceptanceCriteria: ["Verified"])
            try await record(id, [
                .nodeCreated(spec: spec, ticket: ticket),
                .requirementBranchCreated(branch: Self.branch(ticket), from: GH_114Tests.main),
                .requirementBranchObserved(branch: Self.branch(ticket), tip: GH_114Tests.pushed,
                                           main: GH_114Tests.main, containedInMain: false),
                .phaseChanged(to: .proven),
            ])
            let leaf = NodeSpec(id: "\(id)-leaf", parent: id, kind: .leaf, title: "Completed leaf",
                                intent: "Completed implementation", acceptanceCriteria: ["Passed"])
            try await record(leaf.id, [
                .nodeCreated(spec: leaf, ticket: "\(ticket)-LEAF"),
                .phaseChanged(to: .proven),
            ])
            if let number = pullRequest {
                try await record(id, [
                    .requirementPushed(branch: Self.branch(ticket), commit: GH_114Tests.pushed),
                    .requirementPullRequestOpened(number: number, url: Self.url(number)),
                    .requirementPublicationFinished(commit: GH_114Tests.pushed),
                ])
            }
            return id
        }

        func record(_ id: NodeID?, _ kinds: [EventKind], at: Date = GH_114Tests.firstCatchUp,
                    by: Participant = .reconciler) async throws {
            try await ledger.append(kinds.map { LedgerEvent(node: id, by: by, kind: $0, at: at) })
            model.state = await ledger.workingState()
            model.records = await ledger.allRecords()
        }

        func finishVerification(_ id: NodeID, commit: String, passed: Bool) async throws {
            let node = try #require(model.state.nodes[id])
            let evidence = Evidence(check: "final requirement verification", passed: passed,
                                    summary: passed ? "Checks passed" : "Checks failed",
                                    specHash: node.spec.specHash, builtBy: "builder", checkedBy: "verifier",
                                    artifactPath: "evidence/final.txt", artifactSHA256: "artifact-digest", commit: commit)
            try await record(id, [
                .requirementVerificationStarted, .runStarted(run: evidence.checkedBy, role: .verifier),
            ])
            try await record(id, [
                .requirementVerificationFinished(evidence),
                .runFinished(run: evidence.checkedBy, outcome: passed ? "passed" : "failed"),
            ], by: .agent(run: evidence.checkedBy, role: .verifier))
        }

        func baseline(_ commit: String) async throws {
            try await record(nil, [.baselineChecked(Baseline(commit: commit, passed: true, summary: "Passed",
                                                            seconds: 0, log: nil))])
        }
    }

    @MainActor
    private final class OpenedURLs {
        var values: [URL] = []
    }

    private static func actionableHost<Content: View>(_ content: Content, opened: OpenedURLs) -> NSView {
        let view = NSHostingView(rootView: content
            .buttonStyle(ActionableButtonStyle())
            .environment(\.openURL, OpenURLAction { url in
                opened.values.append(url)
                return .handled
            })
            .environment(\.colorScheme, .light)
            .frame(width: 1_400, height: 1_000))
        view.frame = CGRect(x: 0, y: 0, width: 1_400, height: 1_000)
        return view
    }

    private static func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { Self.descendants($0, as: type) }
    }

    private static func press(_ label: String, in view: NSView) throws {
        let button = try #require(Self.descendants(view, as: ActionView.self)
            .first { RenderedUI.shows(label, in: $0.label) }, "Missing actionable link \(label)")
        try #require(button.accessibilityPerformPress(), "The link must accept activation")
    }

    // Hidden SwiftUI controls omit accessibility on some macOS releases. This invokes
    // the actual primitive control trigger, as GH_69Tests' interaction helper does.
    private struct ActionableButtonStyle: PrimitiveButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button(configuration).buttonStyle(DefaultButtonStyle())
                .background(ActionBridge(label: configuration.label, action: configuration.trigger)
                    .allowsHitTesting(false))
        }
    }

    private struct ActionBridge<Label: View>: NSViewRepresentable {
        let label: Label
        let action: () -> Void

        func makeNSView(context: Context) -> ActionView { ActionView() }

        func updateNSView(_ view: ActionView, context: Context) {
            do {
                view.label = try RenderedUI.text(of: label, size: CGSize(width: 300, height: 40))
            } catch {
                Issue.record("Could not read the actionable link label: \(error)")
            }
            view.action = action
        }
    }

    private final class ActionView: NSView {
        var label = ""
        var action: (() -> Void)?

        override func accessibilityPerformPress() -> Bool {
            guard let action else { return false }
            action()
            return true
        }
    }
}
