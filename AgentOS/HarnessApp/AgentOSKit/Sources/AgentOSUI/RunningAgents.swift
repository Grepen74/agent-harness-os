import AgentOSCore
import Foundation
import SwiftUI

public enum OutputWindowPresentation {
    case log
    case changes

    /// Dimensions in which the presented output window may grow and shrink.
    public var resizeAxes: Axis.Set {
        [.horizontal, .vertical]
    }
}

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
                        if let run = node.activeRun { RunRow(node: node, run: run, shown: $shown) }
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

/// One running node. Its width never changes while it runs and its texts truncate, so it can't push the split
/// view's dividers around: re-laying out the window every second made AppKit's window updates time out
/// ("fence tx observer timed out") and the app stop taking input.
struct RunRow: View {
    @Environment(HarnessViewModel.self) private var model
    let node: NodeState
    let run: ActiveRun
    @Binding var shown: RunningAgents.Shown?
    @State private var worktree: URL?
    @State private var log: URL?

    var body: some View {
        let title = "\(node.ticket) · \(run.role.rawValue) · \(run.run)"
        HStack(spacing: 6) {
            Image(systemName: "cpu").foregroundStyle(.orange)
            Text(node.ticket).monospaced().lineLimit(1)
            Text(run.role.rawValue).foregroundStyle(.secondary).lineLimit(1)
            // Updates itself; the hidden widest value keeps its width fixed.
            Text("00:00:00").hidden()
                .overlay(alignment: .leading) { Text(run.since, style: .timer).foregroundStyle(.secondary) }
                .monospacedDigit().lineLimit(1)
            Text(node.spec.title).lineLimit(1).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
            Group {
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
            .fixedSize()
        }
        .font(.caption)
        .controlSize(.small)
        // A run's worktree and log may appear after it started. Only a change redraws the row.
        .task(id: run.run) {
            while !Task.isCancelled {
                let foundWorktree = model.worktree(of: node.id)
                let foundLog = model.agentLog(of: node.id, run: run.run)
                if foundWorktree != worktree { worktree = foundWorktree }
                if foundLog != log { log = foundLog }
                if worktree != nil, log != nil { return }
                try? await Task.sleep(for: .seconds(2))
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
                let latest = Self.tail(of: url)
                if latest != text { text = latest }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .outputWindowPresentation(.log)
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
    @State private var output = TimestampedChangesOutput()

    var body: some View {
        TextSheet(title: title, subtitle: "Changes since the branch left main, committed or not", text: text, follows: false) {
            EmptyView()
        }
        .task(id: node) {
            while !Task.isCancelled {
                let refreshed = await model.changes(of: node)
                text = output.refresh(with: refreshed)
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .outputWindowPresentation(.changes)
    }
}

private extension View {
    func outputWindowPresentation(_ presentation: OutputWindowPresentation) -> some View {
        frame(
            minWidth: presentation.resizeAxes.contains(.horizontal) ? 0 : nil,
            maxWidth: presentation.resizeAxes.contains(.horizontal) ? .infinity : nil,
            minHeight: presentation.resizeAxes.contains(.vertical) ? 0 : nil,
            maxHeight: presentation.resizeAxes.contains(.vertical) ? .infinity : nil
        )
    }
}

private struct TimestampedChangesOutput {
    private struct Line {
        let text: String
        let timestamp: String
    }

    private var lines: [Line] = []

    var text: String {
        lines.map { "[\($0.timestamp)] \($0.text)" }.joined(separator: "\n")
    }

    @discardableResult
    mutating func refresh(with text: String, producedAt: Date = Date()) -> String {
        var existing: [String: [Line]] = Dictionary(grouping: lines, by: \.text)
        let timestamp = timestamp(for: producedAt)
        lines = Self.outputLines(in: text).map { text in
            if var matches = existing[text], !matches.isEmpty {
                let line = matches.removeFirst()
                existing[text] = matches.isEmpty ? nil : matches
                return line
            }
            return Line(text: text, timestamp: timestamp)
        }
        return self.text
    }

    private func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func outputLines(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
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
            LargeText(text: text, follows: follows)
        }
        .padding(12)
        .frame(minWidth: 640, idealWidth: 820, minHeight: 420, idealHeight: 600)
    }
}

/// Read-only, selectable text that stays fast when large. A SwiftUI `Text` lays out all of a 200 KB log on the
/// main thread at every update, which froze the app while a log was open; `NSTextView` lays out lazily.
struct LargeText: NSViewRepresentable {
    let text: String
    let follows: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            if follows { textView.scrollToEndOfDocument(nil) }
        } else if follows, context.coordinator.followed != follows {
            textView.scrollToEndOfDocument(nil)
        }
        context.coordinator.followed = follows
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var followed = false
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
