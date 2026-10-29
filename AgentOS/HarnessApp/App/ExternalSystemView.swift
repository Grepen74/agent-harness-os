import AgentOSCore
import AgentOSSimulation
import AgentOSUI
import SwiftUI

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
