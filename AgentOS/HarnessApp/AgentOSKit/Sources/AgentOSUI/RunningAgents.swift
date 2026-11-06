import AgentOSCore
import SwiftUI

/// What's running right now: one row per node with an agent or check at work, with its live log, its changes
/// so far, and its working copy in Finder or Xcode.
struct RunningAgents: View {
    @Environment(HarnessViewModel.self) private var model
    @State private var shown: Shown?

    var body: some View {
        let running = model.state.running
        // Always present, so an open log stays open when its run (or every run) finishes.
        VStack(spacing: 0) {
            if !running.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Running now (\(running.count))").font(.caption.bold())
                    ForEach(running) { node in
                        if let run = node.activeRun {
                            // Re-checked every second: a run's worktree and log may appear after it started.
                            TimelineView(.periodic(from: .now, by: 1)) { _ in row(node, run) }
                        }
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08))
            }
        }
        .sheet(item: $shown) { shown in
            switch shown {
            case .log(let title, let url): LiveLog(title: title, url: url)
            case .changes(let title, let node): Changes(title: title, node: node)
            }
        }
    }

    private func row(_ node: NodeState, _ run: ActiveRun) -> some View {
        let worktree = model.worktree(of: node.id)
        let log = model.agentLog(of: node.id, run: run.run)
        let title = "\(node.ticket) · \(run.role.rawValue) · \(run.run)"
        return HStack(spacing: 6) {
            Image(systemName: "cpu").foregroundStyle(.orange)
            Text(node.ticket).monospaced()
            Text(run.role.rawValue).foregroundStyle(.secondary)
            Text(run.since, style: .timer).monospacedDigit().foregroundStyle(.secondary)
            Text(node.spec.title).lineLimit(1).foregroundStyle(.secondary)
            Spacer()
            Button("Log") { if let log { shown = .log(title, log) } }
                .disabled(log == nil)
                .help(log == nil ? "This run writes no log (checks record theirs as evidence when done)" : "Follow the agent's output live")
            Button("Changes") { shown = .changes(title, node.id) }
                .disabled(worktree == nil)
                .help("What the working copy changed so far, committed or not")
            Button { if let worktree { model.reveal(worktree) } } label: { Image(systemName: "folder") }
                .disabled(worktree == nil)
                .help("Show the working copy in Finder")
            Button { if let worktree { model.openInXcode(worktree) } } label: { Image(systemName: "hammer") }
                .disabled(worktree == nil)
                .help("Open the working copy in Xcode. Look, don't change: anything changed there is committed as the agent's work.")
        }
        .font(.caption)
        .controlSize(.small)
    }

    enum Shown: Identifiable {
        case log(String, URL)
        case changes(String, NodeID)
        var id: String {
            switch self {
            case .log(_, let url): "log " + url.path
            case .changes(let title, _): "changes " + title
            }
        }
    }
}

/// Follows a growing log file, scrolled to the end unless you turn that off.
struct LiveLog: View {
    let title: String
    let url: URL
    @State private var text = ""
    @State private var follows = true

    var body: some View {
        TextSheet(title: title, subtitle: url.path, text: text.isEmpty ? "Nothing written yet…" : text, follows: follows) {
            Toggle("Follow", isOn: $follows).toggleStyle(.checkbox)
        }
        .task(id: url) {
            while !Task.isCancelled {
                text = Self.tail(of: url)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The end of the file: logs can grow large, and the latest output is what matters while it runs.
    static func tail(of url: URL, bytes: Int = 200_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return (start > 0 ? "…\n" : "") + String(decoding: data, as: UTF8.self)
    }
}

/// A node's changes so far, refreshed every few seconds while open.
struct Changes: View {
    @Environment(HarnessViewModel.self) private var model
    let title: String
    let node: NodeID
    @State private var text = "Loading…"

    var body: some View {
        TextSheet(title: title, subtitle: "Changes since the branch left main, committed or not", text: text, follows: false) {
            EmptyView()
        }
        .task(id: node) {
            while !Task.isCancelled {
                text = await model.changes(of: node)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct TextSheet<Extra: View>: View {
    let title: String
    let subtitle: String
    let text: String
    let follows: Bool
    @ViewBuilder let extra: () -> Extra
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                extra()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(.background.secondary)
                .onChange(of: text) { if follows { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { if follows { proxy.scrollTo("end", anchor: .bottom) } }
            }
        }
        .padding(12)
        .frame(minWidth: 640, idealWidth: 820, minHeight: 420, idealHeight: 600)
    }
}

/// A node's earlier agent runs, each with its log if it kept one.
struct AgentRuns: View {
    @Environment(HarnessViewModel.self) private var model
    let node: NodeState

    var body: some View {
        let runs = Self.runs(of: node.id, in: model.records)
        if !runs.isEmpty {
            Text("Agent runs").font(.caption.bold()).padding(.top, 4)
            ForEach(runs, id: \.run) { item in
                HStack {
                    Text(item.role.rawValue)
                    Text(item.run).monospaced().foregroundStyle(.secondary)
                    Text(item.outcome ?? "running…").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let log = model.agentLog(of: node.id, run: item.run) {
                        Button("Log") { model.open(log.path) }.controlSize(.small)
                    }
                }
                .font(.caption)
            }
        }
    }

    struct Item {
        let run: RunID
        let role: AgentRole
        var outcome: String?
    }

    /// Agent runs only: checks are the verifier's, and their logs are already listed as evidence.
    static func runs(of node: NodeID, in records: [RecordedEvent]) -> [Item] {
        var items: [Item] = []
        for record in records where record.event.node == node {
            switch record.event.kind {
            case .runStarted(let run, let role) where role != .verifier:
                items.append(Item(run: run, role: role))
            case .runFinished(let run, let outcome):
                if let index = items.firstIndex(where: { $0.run == run }) { items[index].outcome = outcome }
            default:
                break
            }
        }
        return items
    }
}
