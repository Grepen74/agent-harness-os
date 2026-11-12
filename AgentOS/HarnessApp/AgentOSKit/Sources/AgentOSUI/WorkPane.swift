import AgentOSCore
import SwiftUI

/// The harness's own view: the Work Node tree from the ledger, what needs a human, and the
/// other team's system (doc 06: observability).
public struct WorkPane: View {
    @Environment(HarnessViewModel.self) private var model
    @State private var selection: NodeID?
    @State private var showDoneNodes: Bool = true

    public init() {}

    public var body: some View {
        VSplitView {
            VStack(alignment: .trailing, spacing: 0) {
                PaneHeader(title: "Work tree", subtitle: "Derived from the ledger. Tickets only mirror this.")
                AttentionList()
                RunningAgents()
                List(selection: $selection) {
                    OutlineGroup(model.state.roots.filter({
                        guard showDoneNodes == false else { return true }
                        return $0.phase != .proven
                    }).map { TreeItem($0, in: model.state) }, children: \.children) { item in
                        NodeRow(node: item.node, status: model.state.status(of: item.node)).tag(item.node.id)
                    }
                }
                Toggle("Show Done items", isOn: $showDoneNodes)
                    .padding()
            }
            .frame(minHeight: 260, maxHeight: .infinity)

            Group {
                if let id = selection, let node = model.state.nodes[id] {
                    NodeDetail(node: node)
                } else {
                    ContentUnavailableView("No node selected", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
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
    /// The same words as on the ticket; the phase is in the detail pane.
    let status: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(node.phase.color).frame(width: 9, height: 9)
            Text(node.displayName).monospaced().foregroundStyle(.secondary)
            Text(node.spec.title).lineLimit(1)
            Spacer()
            ForEach(Flag.allCases.filter { node.flags[$0] != nil }, id: \.self) { flag in
                Image(systemName: flag.symbol).foregroundStyle(flag.color).help(node.flags[flag] ?? "")
            }
            if let run = node.activeRun { Label(run.role.rawValue, systemImage: "cpu").font(.caption).foregroundStyle(.orange) }
            Text(status).font(.caption).foregroundStyle(node.phase.color).help("Phase: \(node.phase.rawValue)")
        }
    }
}

struct AttentionList: View {
    @Environment(HarnessViewModel.self) private var model

    var body: some View {
        let items = model.state.attentionList
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Needs attention").font(.caption.bold())
                // A node can have several flags at once.
                ForEach(items.map { (id: "\($0.node.id) \($0.flag.rawValue)", item: $0) }, id: \.id) { entry in
                    let item = entry.item
                    Label("\(item.node.displayName): \(item.reason)", systemImage: item.flag.symbol)
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
                AgentRuns(node: node)
                if !node.reviews.isEmpty {
                    Text("Reviews").font(.caption.bold()).padding(.top, 4)
                    ForEach(Array(node.reviews.enumerated()), id: \.offset) { _, review in
                        VStack(alignment: .leading, spacing: 3) {
                            Label("\(review.stage.rawValue): \(review.result.passed ? "Passed" : "Findings")",
                                  systemImage: review.result.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .foregroundStyle(review.result.passed ? .green : .red)
                            Text("commit \(review.commit.prefix(8))").monospaced().foregroundStyle(.secondary)
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
                    ForEach(Array(node.evidence.enumerated()), id: \.offset) { _, evidence in
                        HStack(alignment: .top) {
                            Image(systemName: evidence.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .foregroundStyle(evidence.passed ? .green : .red)
                            VStack(alignment: .leading) {
                                Text("\(evidence.check): \(evidence.summary)")
                                Text("built by \(evidence.builtBy), checked by \(evidence.checkedBy)").foregroundStyle(.secondary)
                                Text("commit \(String(evidence.commit.prefix(8)))").monospaced().foregroundStyle(.secondary)
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
            row("Test target", node.spec.kind == .leaf ? node.spec.testTarget : "–")
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
