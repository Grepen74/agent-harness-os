import AgentOSCore
import SwiftUI

struct ProcessSelectedNode: View {
    @Environment(HarnessViewModel.self) private var model
    let summary: ProcessNodeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected node in Work").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(model.state.nodes[summary.nodeID]?.spec.title ?? summary.nodeID).font(.title3.bold())
                Text(summary.status).foregroundStyle(.secondary)
                if summary.interrupted {
                    Label("Interrupted", systemImage: "pause.circle").foregroundStyle(.orange)
                }
                Spacer()
                Button("Clear node selection") { model.selectedNodeID = nil }
            }
            Text("Current stage: \(summary.stageTitle)").font(.headline)
            if let reason = summary.waitReason {
                Text(reason).fixedSize(horizontal: false, vertical: true)
            }
            let counters = summary.counters
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { counterLabels(counters) }
                VStack(alignment: .leading, spacing: 8) { counterLabels(counters) }
            }
            Text("Review: \(summary.reviewLevel.rawValue)").font(.caption).foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func counterLabels(_ counters: ProcessNodeCounters) -> some View {
        counter("Failed attempts", counters.failedAttempts, counters.maxAttempts)
        counter("Landing reworks", counters.landingReworks, counters.maxReworks)
        counter("Agent runs since a person acted", counters.agentRunsSinceHuman, counters.maxAgentRuns)
        if let stage = counters.reviewStage {
            VStack(alignment: .leading, spacing: 2) {
                counter("Failed \(stage.rawValue) reviews", counters.failedReviews, counters.reviewRoundAllowance)
                if counters.reviewRoundAllowance > counters.reviewMaxRounds {
                    Text("Converging; usual limit \(counters.reviewMaxRounds), at most 2 × maxRounds.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func counter(_ title: String, _ value: Int, _ limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(value) / \(limit)").font(.title3.monospaced())
        }
    }
}
