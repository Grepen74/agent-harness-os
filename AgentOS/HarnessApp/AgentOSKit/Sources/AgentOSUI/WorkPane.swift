import AgentOSCore
import SwiftUI

/// The harness's own view: the Work Node tree from the ledger, what needs a human, and the
/// other team's system (doc 06: observability).
public struct WorkPane: View {
    @Environment(HarnessViewModel.self) private var model
    @State private var showDoneNodes: Bool = true

    public init() {}

    public var body: some View {
        VSplitView {
            VStack(alignment: .trailing, spacing: 0) {
                PaneHeader(title: "Work tree", subtitle: "Derived from the ledger. Tickets only mirror this.")
                AttentionList()
                RunningAgents()
                if let stageID = model.workStageFilterID {
                    HStack {
                        Text("Stage: \(WorkflowCatalog.standard.stages.first { $0.id == stageID }?.title ?? stageID)")
                            .lineLimit(1)
                        Text("\(model.matchingWorkNodeIDs.count) matching nodes")
                            .foregroundStyle(.secondary).fixedSize()
                        Spacer()
                        Button("Clear stage filter") { model.clearWorkStageFilter() }
                    }
                    .padding(8)
                }
                List(selection: workSelection) {
                    if model.workStageFilterID != nil {
                        ForEach(filteredRows, id: \.node.id) { row in
                            HStack {
                                NodeRow(node: row.node, status: model.state.appStatus(of: row.node))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if !model.matchingWorkNodeIDs.contains(row.node.id) {
                                    Text("Context").font(.caption).foregroundStyle(.secondary).fixedSize()
                                }
                            }
                            .padding(.leading, CGFloat(row.depth) * 16)
                            .tag(row.node.id)
                        }
                    } else {
                        OutlineGroup(Self.roots(in: model.state, showingDone: showDoneNodes)
                            .map { TreeItem($0, in: model.state) }, children: \.children) { item in
                            NodeRow(node: item.node, status: model.state.appStatus(of: item.node)).tag(item.node.id)
                        }
                    }
                }
                Toggle("Show Done and closed items", isOn: $showDoneNodes)
                    .padding()
            }
            .frame(minHeight: 260, maxHeight: .infinity)

            Group {
                if let id = model.selectedNodeID, let node = model.state.nodes[id] {
                    NodeDetail(node: node)
                } else {
                    ContentUnavailableView("No node selected", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
        }
    }

    private var workSelection: Binding<NodeID?> {
        Binding(get: { model.selectedNodeID }, set: { selection in
            // A filtered-out node remains the Process selection even if List drops its row selection.
            if selection == nil, model.workStageFilterID != nil,
               let selected = model.selectedNodeID, !model.visibleWorkNodeIDs.contains(selected) { return }
            model.selectedNodeID = selection
        })
    }

    private var filteredRows: [(node: NodeState, depth: Int)] {
        let visible = model.visibleWorkNodeIDs
        func rows(_ nodes: [NodeState], depth: Int) -> [(node: NodeState, depth: Int)] {
            nodes.filter { visible.contains($0.id) }.flatMap { node in
                [(node: node, depth: depth)] + rows(
                    node.children.compactMap { model.state.nodes[$0] }, depth: depth + 1)
            }
        }
        return rows(model.state.roots, depth: 0)
    }

    /// Open pull requests stay visible; Done and closed requirements are hidden even with attention.
    static func roots(in state: WorkingState, showingDone: Bool) -> [NodeState] {
        guard !showingDone else { return state.roots }
        let attention = Set(state.attentionList.map(\.node.id))
        func needsAttention(_ id: NodeID) -> Bool {
            attention.contains(id) || (state.nodes[id]?.children.contains(where: needsAttention) ?? false)
        }
        return state.roots.filter {
            guard $0.pullRequestState != .merged, $0.pullRequestState != .closed,
                  state.status(of: $0) != "Done" else { return false }
            if $0.pullRequestState == .open { return true }
            return ($0.phase != .proven && !$0.ticketClosed) || needsAttention($0.id)
        }
    }
}

struct TreeItem: Identifiable {
    let node: NodeState
    let children: [TreeItem]?
    var id: NodeID { node.id }

    init(_ node: NodeState, in state: WorkingState) {
        self.node = node
        let kids = node.children.compactMap { state.nodes[$0] }.map { TreeItem($0, in: state) }
        children = kids.isEmpty ? nil : kids
    }
}

struct NodeRow: View {
    let node: NodeState
    /// The app status, including verification detail for open pull requests.
    let status: String

    /// Closed on the tracker and not finished: greyed out, its flags kept in the ledger but not shown.
    private var closed: Bool { node.ticketClosed && node.phase != .proven }
    private var color: Color { closed ? .secondary : node.phase.color }

    var body: some View {
        NodeRowLayout {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(node.displayName).monospaced().lineLimit(1).foregroundStyle(.secondary)
            Text(node.spec.title).lineLimit(1).foregroundStyle(closed ? .secondary : .primary)
            HStack(spacing: 6) {
                ForEach(Flag.allCases.filter { !closed && node.flags[$0] != nil }, id: \.self) { flag in
                    Image(systemName: flag.symbol).foregroundStyle(flag.color).help(node.flags[flag] ?? "")
                }
                if let run = node.activeRun {
                    Label(run.role.rawValue, systemImage: "cpu").font(.caption).foregroundStyle(.orange)
                }
                Text(status).font(.caption).foregroundStyle(color).help("Phase: \(node.phase.rawValue)")
            }
        }
    }
}

/// A work-tree row: dot, key, title, and the flags and status at the trailing edge. A long title truncates first,
/// but keeps up to `titleShare` once the status and key have their minimums; after that the status wraps, and the
/// key gives way only in a very narrow row.
/// (Layout priorities can't say this: a prioritised title took all the space and left the status one character wide.)
struct NodeRowLayout: Layout {
    var spacing: CGFloat = 6
    var titleShare: CGFloat = 160
    var keyMinimum: CGFloat = 16
    var trailingMinimum: CGFloat = 48

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let widths = widths(for: width, subviews)
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: width ?? widths.reduce(gaps, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(for: bounds.width, subviews)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            if index == subviews.count - 1 { x = bounds.maxX - widths[index] }
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: widths[index], height: nil))
            x += widths[index] + spacing
        }
    }

    /// Dot, key, title, trailing.
    private func widths(for width: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard let width, ideal.count == 4 else { return ideal }
        let (dot, key, title, trailing) = (ideal[0], ideal[1], ideal[2], ideal[3])
        let available = max(0, width - dot - spacing * 3)
        let floor = min(titleShare, max(0, available - min(trailing, trailingMinimum) - min(key, keyMinimum)))
        let titleWidth = min(title, available, max(available - key - trailing, floor))
        let rest = available - titleWidth
        let trailingWidth = min(trailing, max(0, rest - min(key, keyMinimum)))
        return [dot, min(key, max(0, rest - trailingWidth)), titleWidth, trailingWidth]
    }
}

struct AttentionList: View {
    @Environment(HarnessViewModel.self) private var model

    var body: some View {
        let items = model.state.attentionList
        if !items.isEmpty || model.state.mainFetchWarning != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("Needs attention").font(.caption.bold())
                if let warning = model.state.mainFetchWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A node can have several flags at once.
                ForEach(items.map { (id: "\($0.node.id) \($0.flag.rawValue) \($0.reason)", item: $0) }, id: \.id) { entry in
                    let item = entry.item
                    let message = item.reason.hasPrefix("\(item.node.ticket): ")
                        ? item.reason : "\(item.node.displayName): \(item.reason)"
                    Label(message, systemImage: item.flag.symbol)
                        .font(.caption)
                        .foregroundStyle(item.flag.color)
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08))
        }
    }
}

struct NodeDetail: View {
    @Environment(HarnessViewModel.self) private var model
    let node: NodeState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(node.spec.id) · \(node.spec.kind.rawValue)").font(.headline)
                grid
                if let details = model.pullRequestDetails(for: node.id) {
                    PullRequestSection(details: details)
                }
                if let message = model.state.overlapHoldMessage(for: node) {
                    Label(message, systemImage: "pause.circle")
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 640, alignment: .leading)
                }
                AgentRuns(node: node)
                if !node.reviews.isEmpty {
                    Text("Reviews").font(.caption.bold()).padding(.top, 4)
                    ForEach(Array(node.reviews.enumerated().reversed()), id: \.offset) { _, review in
                        VStack(alignment: .leading, spacing: 3) {
                            Label("\(review.stage.rawValue): \(review.result.passed ? "Passed" : "Findings")",
                                  systemImage: review.result.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .foregroundStyle(review.result.passed ? .green : .red)
                            Text(["commit \(review.commit.prefix(8))", review.recordedAt?.ledgerStamp].compactMap { $0 }.joined(separator: " · "))
                                .monospaced().foregroundStyle(.secondary)
                            ForEach(Array(review.result.findings.enumerated()), id: \.offset) { _, finding in
                                Text(finding).textSelection(.enabled)
                            }
                            if let evidence = review.uiEvidence {
                                ForEach(evidence.snapshotPaths, id: \.self) { path in
                                    reviewArtifact("Snapshot", path: path)
                                }
                                if let path = evidence.beforeScreenshot { reviewArtifact("Before", path: path) }
                                if let path = evidence.afterScreenshot { reviewArtifact("After", path: path) }
                                Text("Windows opened: \(evidence.windowsOpened ? "yes" : "no"); closed: \(evidence.windowsClosed ? "yes" : "no")")
                            }
                        }
                        .font(.caption)
                    }
                }
                if node.awaitingHumanReview {
                    Text("Review this candidate, then add harness:build to approve it.").font(.caption)
                }
                if !node.evidence.isEmpty {
                    Text("Evidence").font(.caption.bold()).padding(.top, 4)
                    ForEach(Array(node.evidence.enumerated().reversed()), id: \.offset) { _, evidence in
                        HStack(alignment: .top) {
                            Image(systemName: evidence.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .foregroundStyle(evidence.passed ? .green : .red)
                            VStack(alignment: .leading) {
                                Text("\(evidence.check): \(evidence.summary)")
                                Text("built by \(evidence.builtBy), checked by \(evidence.checkedBy)").foregroundStyle(.secondary)
                                Text(["commit \(evidence.commit.prefix(8))", evidence.recordedAt?.ledgerStamp].compactMap { $0 }.joined(separator: " · "))
                                    .monospaced().foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Log") { model.open(evidence.artifactPath) }.controlSize(.small)
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            row("Ticket", [node.displayName, model.ticket(node.ticket)?.title].compactMap { $0 }.joined(separator: "  "))
            row("Phase", node.phase.rawValue)
            row("Gates", node.gates.isEmpty ? "– (inherited from parent if any)" : node.gates.map(\.rawValue).sorted().joined(separator: ", "))
            row("Links", node.links.isEmpty ? "–" : node.links.map { "\($0.type.rawValue) \($0.to)" }.joined(separator: "\n"))
            row("Touches", node.spec.touches.isEmpty ? "–" : node.spec.touches.joined(separator: ", "))
            row("Paths", node.spec.predictedPaths.isEmpty ? "–" : node.spec.predictedPaths.joined(separator: "\n"))
            row("Test target", node.spec.kind == .leaf ? node.spec.testTarget : "–")
            row("Affected tests", node.spec.affectedTests.isEmpty ? "–" : node.spec.affectedTests.joined(separator: "\n"))
            row("Attempts failed", "\(node.failedAttempts)")
            row("Reworks", "\(node.reworks)")
            row("Landed at", node.landedCommit.map { String($0.prefix(8)) } ?? "–")
            row("Tests fingerprint", node.testsDigest.map { String($0.prefix(12)) } ?? "–")
            row("Spec hash", String(node.spec.specHash.prefix(12)))
        }
        .font(.caption)
    }

    private func reviewArtifact(_ title: String, path: String) -> some View {
        Button("\(title): \(path)") {
            let resolved = path.hasPrefix("/") ? path : model.worktree(of: node.id)?.appending(path: path).path ?? path
            model.open(resolved)
        }
        .controlSize(.small)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

extension Flag {
    var symbol: String {
        switch self {
        case .escalated: "exclamationmark.triangle.fill"
        case .blocked: "pause.circle.fill"
        case .needsInput: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .escalated: .red
        case .blocked: .orange
        case .needsInput: .blue
        }
    }
}
