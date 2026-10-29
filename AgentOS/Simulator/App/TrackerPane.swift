import AgentOSCore
import SwiftUI

/// What humans see: a plain issue tracker. The harness only reads labels set by humans and writes
/// comments and statuses back (doc 03, doc 05).
struct TrackerPane: View {
    @Environment(SimulatorModel.self) private var model
    @State private var selection: String?
    @State private var editor: TicketEditor.Mode?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    PaneHeader(title: "Tracker", subtitle: "Humans work here. Labels are the signals.")
                    Button { editor = .new } label: { Image(systemName: "plus") }.padding(.trailing, 12).help("New ticket")
                }
                List(treeOrdered, id: \.ticket.key, selection: $selection) { ticket, depth in
                    HStack {
                        Text(ticket.key).monospaced().foregroundStyle(.secondary)
                        Text(ticket.title).lineLimit(1)
                        Spacer()
                        Text(ticket.status).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    .padding(.leading, CGFloat(depth) * 16)
                    .tag(ticket.key)
                }
            }
            .frame(minHeight: 180)

            Group {
                if let ticket = model.ticket(selection) {
                    TicketDetail(ticket: ticket) { editor = .edit(ticket) }
                } else {
                    ContentUnavailableView("No ticket selected", systemImage: "ticket",
                                           description: Text("Load the demo from the ⚙︎ menu, or create a ticket."))
                }
            }
            .frame(minHeight: 260)
        }
        .sheet(item: $editor) { TicketEditor(mode: $0) }
    }

    /// Depth-first: each ticket directly followed by its children, so a breakdown stays under its parent.
    private var treeOrdered: [(ticket: Ticket, depth: Int)] {
        let keys = Set(model.tickets.map(\.key))
        let children = Dictionary(grouping: model.tickets) { $0.parentKey }
        func walk(_ parent: String?, _ depth: Int) -> [(ticket: Ticket, depth: Int)] {
            (children[parent] ?? []).flatMap { [($0, depth)] + walk($0.key, depth + 1) }
        }
        // Tickets whose parent is unknown are treated as roots so nothing disappears.
        let orphans = model.tickets.filter { $0.parentKey.map { !keys.contains($0) } ?? false }
        return walk(nil, 0) + orphans.flatMap { [($0, 0)] + walk($0.key, 1) }
    }
}

struct TicketDetail: View {
    @Environment(SimulatorModel.self) private var model
    let ticket: Ticket
    let edit: () -> Void
    @State private var draft = ""

    private let simulationLabels = ["sim:fail-once", "sim:always-fail", "sim:stuck"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(ticket.key)  \(ticket.title)").font(.title3.bold())
                    Spacer()
                    Button("Edit", action: edit)
                }
                Text(ticket.description.isEmpty ? "(no description)" : ticket.description)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Acceptance criteria").font(.caption.bold())
                    if ticket.acceptanceCriteria.isEmpty { Text("(none)").foregroundStyle(.secondary) }
                    ForEach(ticket.acceptanceCriteria, id: \.self) { Text("• \($0)") }
                    if !ticket.blockedBy.isEmpty {
                        Text("Needs from other systems: \(ticket.blockedBy.joined(separator: ", "))").font(.caption)
                    }
                }

                HStack {
                    ForEach(ticket.labels, id: \.name) { label in
                        HStack(spacing: 4) {
                            Image(systemName: label.setBy.icon)
                            Text(label.name)
                            Button { Task { await model.removeLabel(label.name, from: ticket.key) } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                        }
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(label.name.hasPrefix("harness:") ? Color.accentColor.opacity(0.2) : Color.yellow.opacity(0.25), in: Capsule())
                        .help("Set by \(label.setBy.label)")
                    }
                    Menu("Add label") {
                        Section("Signals to the harness") {
                            ForEach(HarnessCommand.allCases, id: \.self) { command in
                                Button(command.label) { Task { await model.addLabel(command.label, to: ticket.key) } }
                            }
                        }
                        Section("Simulation (make agents misbehave)") {
                            ForEach(simulationLabels, id: \.self) { name in
                                Button(name) { Task { await model.addLabel(name, to: ticket.key) } }
                            }
                        }
                    }
                    .fixedSize()
                }

                Divider()
                ForEach(ticket.comments) { comment in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(comment.author.label, systemImage: comment.author.icon).font(.caption.bold())
                        Text(comment.text).font(.callout.monospaced()).textSelection(.enabled)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    TextField("Comment as \(model.you)…", text: $draft)
                    Button("Post") {
                        let text = draft
                        draft = ""
                        Task { await model.comment(text, on: ticket.key) }
                    }
                    .disabled(draft.isEmpty)
                }
            }
            .padding(12)
        }
    }
}

struct TicketEditor: View {
    enum Mode: Identifiable {
        case new
        case edit(Ticket)
        var id: String { if case .edit(let ticket) = self { ticket.key } else { "new" } }
    }

    @Environment(SimulatorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var title = ""
    @State private var description = ""
    @State private var criteria = ""
    @State private var blockedBy = ""

    init(mode: Mode) {
        self.mode = mode
        if case .edit(let ticket) = mode {
            _title = State(initialValue: ticket.title)
            _description = State(initialValue: ticket.description)
            _criteria = State(initialValue: ticket.acceptanceCriteria.joined(separator: "\n"))
            _blockedBy = State(initialValue: ticket.blockedBy.joined(separator: ", "))
        }
    }

    var body: some View {
        Form {
            TextField("Title", text: $title)
            TextField("Description (the why)", text: $description, axis: .vertical).lineLimit(2...4)
            LabeledContent("Acceptance criteria\n(one per line)") {
                TextEditor(text: $criteria).frame(height: 90).font(.body)
            }
            TextField("Needs from other systems (e.g. BACKEND-42)", text: $blockedBy)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(title.isEmpty)
            }
        }
        .padding()
        .frame(width: 480)
    }

    private func save() {
        let lines = criteria.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let refs = blockedBy.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task {
            switch mode {
            case .new: await model.createTicket(title: title, description: description, criteria: lines, blockedBy: refs)
            case .edit(let ticket): await model.edit(ticket.key, title: title, description: description, criteria: lines, blockedBy: refs)
            }
        }
        dismiss()
    }
}
