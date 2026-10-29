import AgentOSCore
import SwiftUI

/// The harness's own view: the Work Node tree from the ledger, what needs a human, and the
/// other team's system (doc 06: observability).
struct WorkPane: View {
    @Environment(SimulatorModel.self) private var model
    @State private var selection: NodeID?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                PaneHeader(title: "Work tree", subtitle: "Derived from the ledger. Tickets only mirror this.")
                AttentionList()
                List(selection: $selection) {
                    OutlineGroup(model.state.roots.map { TreeItem($0, in: model.state) }, children: \.children) { item in
                        NodeRow(node: item.node).tag(item.node.id)
                    }
                }
            }
            .frame(minHeight: 260)

            Group {
                if let id = selection, let node = model.state.nodes[id] {
                    NodeDetail(node: node)
                } else {
                    ContentUnavailableView("No node selected", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .frame(minHeight: 160)

            ExternalSystemView().frame(minHeight: 120)
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

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(node.phase.color).frame(width: 9, height: 9)
            Text(node.ticket).monospaced().foregroundStyle(.secondary)
            Text(node.spec.title).lineLimit(1)
            Spacer()
            if node.flags[.escalated] != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            if node.flags[.blocked] != nil { Image(systemName: "pause.circle.fill").foregroundStyle(.orange) }
            if let run = node.activeRun { Label(run.role.rawValue, systemImage: "cpu").font(.caption).foregroundStyle(.orange) }
            Text(node.phase.rawValue).font(.caption).foregroundStyle(node.phase.color)
        }
    }
}

struct AttentionList: View {
    @Environment(SimulatorModel.self) private var model

    var body: some View {
        let items = model.state.attentionList
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Needs attention").font(.caption.bold())
                ForEach(items, id: \.node.id) { item in
                    Label("\(item.node.ticket): \(item.reason)",
                          systemImage: item.flag == .escalated ? "exclamationmark.triangle.fill" : "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(item.flag == .escalated ? .red : .orange)
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.08))
        }
    }
}

struct NodeDetail: View {
    @Environment(SimulatorModel.self) private var model
    let node: NodeState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(node.spec.id) · \(node.spec.kind.rawValue)").font(.headline)
                grid
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

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// Stand-in for another team's backlog in another system. Delivering an item mimics the outside
/// world changing; the harness notices on its next round (doc 03: adapters report, never decide).
struct ExternalSystemView: View {
    @Environment(SimulatorModel.self) private var model
    @State private var newKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Other team's system", subtitle: "You play them: deliver items when they're done.")
            List {
                ForEach(model.externalItems) { item in
                    HStack {
                        Text(item.key).monospaced()
                        Text(item.title).lineLimit(1)
                        Text(item.owner).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if item.delivered {
                            Label("Delivered", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                        } else {
                            Button("Mark delivered") { Task { await model.deliver(item.key) } }.controlSize(.small)
                        }
                    }
                }
                HStack {
                    TextField("New item key, e.g. BACKEND-7", text: $newKey)
                    Button("Add") {
                        let key = newKey
                        newKey = ""
                        Task { await model.addExternal(key: key, title: "Requested by the app team", owner: "Other team") }
                    }
                    .disabled(newKey.isEmpty)
                }
            }
        }
    }
}
