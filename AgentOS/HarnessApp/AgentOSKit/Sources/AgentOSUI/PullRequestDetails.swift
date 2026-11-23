import AgentOSCore
import Foundation
import SwiftUI

/// Ledger-backed facts for a requirement's pull request, independent of the current verification attempt.
public struct PullRequestDetails: Sendable {
    public let number: Int
    public let url: URL
    public let pushedCommit: String?
    public let status: VerificationCommitStatus?
    public let verifiedCommit: String?
    public let verificationPassed: Bool?
    public let containsLatestMain: Bool?
    public let catchUpMain: String?
    public let caughtUpAt: Date?
    public let queuePosition: Int?
}

extension HarnessViewModel {
    public func pullRequestDetails(for node: NodeID) -> PullRequestDetails? {
        guard let node = state.nodes[node], node.spec.parent == nil,
              let number = node.pullRequestNumber, let recordedURL = node.pullRequestURL,
              let url = URL(string: recordedURL) else { return nil }
        let result = node.lastCompletedRequirementVerification
        let containment = node.requirementBranchContainmentObservation
        let tip = node.requirementBranchObservation?.tip ?? node.lastPushedCommit ?? node.publishedCommit
        let containsMain: Bool?
        if let containment, containment.branch == node.requirementBranch,
           containment.tip == tip,
           state.baseline == nil || containment.main == state.baseline?.commit {
            containsMain = containment.containsMain
        } else {
            containsMain = nil
        }
        return PullRequestDetails(
            number: number, url: url, pushedCommit: node.lastPushedCommit,
            status: node.lastPushedCommit.flatMap { node.verificationCommitStatuses[$0] },
            verifiedCommit: result?.commit, verificationPassed: result?.passed,
            containsLatestMain: containsMain, catchUpMain: node.lastCatchUpSuccess?.mainSHA,
            caughtUpAt: node.lastCaughtUpAt,
            queuePosition: state.verificationQueue.firstIndex { $0.id == node.id }.map { $0 + 1 })
    }
}

struct PullRequestSection: View {
    let details: PullRequestDetails
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        Text("Pull request").font(.caption.bold()).padding(.top, 4)
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            GridRow {
                Text("Pull request").foregroundStyle(.secondary)
                Link("#\(details.number)", destination: details.url)
            }
            row("Last pushed commit", short(details.pushedCommit))
            row("agentos/verified", status)
            row("Last verified commit", verification)
            row("Contains latest main", details.containsLatestMain.map { $0 ? "Yes" : "No" } ?? "Unknown")
            row("Last catch-up", catchUp)
            row("Verification queue", details.queuePosition.map { "Position \($0)" } ?? "Not waiting")
        }
        .font(.caption)
    }

    private var status: String {
        switch details.status {
        case .pending: "Pending"
        case .success: "Success"
        case .failure: "Failure"
        case nil: "Not posted"
        }
    }

    private var verification: String {
        guard let passed = details.verificationPassed else { return "Not verified" }
        return "\(short(details.verifiedCommit)) · \(passed ? "Passed" : "Failed")"
    }

    private var catchUp: String {
        guard let main = details.catchUpMain, let date = details.caughtUpAt else { return "None" }
        let time = date.formatted(Date.FormatStyle(
            date: .numeric, time: .standard, locale: locale, timeZone: timeZone))
        return "\(short(main)) · \(time)"
    }

    private func short(_ commit: String?) -> String {
        commit.map { String($0.prefix(8)) } ?? "Not pushed"
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
