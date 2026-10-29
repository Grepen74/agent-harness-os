import AgentOSUI
import AppKit
import SwiftUI

/// A window for one real repo: readiness findings and the repo's ledger.
struct RepositoryView: View {
    @State private var model: RepositoryModel

    init(url: URL) { _model = State(initialValue: RepositoryModel(url: url)) }

    var body: some View {
        HSplitView {
            FindingsPane().frame(minWidth: 480, idealWidth: 640)
            LedgerPane().frame(minWidth: 340, idealWidth: 420)
        }
        .environment(model.view)
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle(model.name)
        .navigationSubtitle(model.url.path)
        .task { await model.rescan() }
        .toolbar {
            ToolbarItemGroup {
                Button { model.revealRepository() } label: { Label("Show repo in Finder", systemImage: "folder") }
                    .help("Show the repo in Finder")
                Button { model.revealStorage() } label: { Label("Show harness data", systemImage: "externaldrive") }
                    .help("Show the harness's own data for this repo (outside the repo)")
                    .disabled(model.storage == nil)
            }
        }
    }
}

/// File menu: Open Repository… and the simulator.
struct RepositoryCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") {
                if let url = Self.chooseRepository() { openWindow(value: url) }
            }
            .keyboardShortcut("o")
            Button("Show Simulator") { openWindow(id: AgentOSHarnessApp.simulatorID) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }

    @MainActor
    private static func chooseRepository() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a git repo. The harness only reads it."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
