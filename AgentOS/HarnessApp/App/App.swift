import AgentOSCore
import AgentOSUI
import SwiftUI

@main
struct AgentOSHarnessApp: App {
    @State private var model = SimulatorModel()

    var body: some Scene {
        WindowGroup("AgentOS Simulator") {
            ContentView()
                .environment(model)
                .environment(model.view)
                .frame(minWidth: 1200, minHeight: 700)
        }
    }
}

struct ContentView: View {
    @Environment(SimulatorModel.self) private var model

    var body: some View {
        HSplitView {
            TrackerPane().frame(minWidth: 340, idealWidth: 400)
            VSplitView {
                WorkPane().frame(minHeight: 420)
                ExternalSystemView().frame(minHeight: 120)
            }
            .frame(minWidth: 380, idealWidth: 460)
            LedgerPane().frame(minWidth: 340, idealWidth: 420)
        }
        .toolbar { HarnessToolbar() }
    }
}

struct HarnessToolbar: ToolbarContent {
    @Environment(SimulatorModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        @Bindable var view = model.view
        ToolbarItemGroup(placement: .navigation) {
            Toggle(isOn: Binding(get: { model.isRunning }, set: { model.setRunning($0) })) {
                Label(model.isRunning ? "Running" : "Stopped", systemImage: model.isRunning ? "pause.fill" : "play.fill")
            }
            .help("Run the reconciler continuously (one round per second)")
            Button { Task { await model.step() } } label: { Label("Step", systemImage: "forward.frame") }
                .help("Run exactly one reconciler round")
                .disabled(model.isRunning || model.isBusy)
            // Always in the layout, only visible for slow rounds: avoids the toolbar jumping every second.
            ProgressView().controlSize(.small).opacity(model.showsActivity ? 1 : 0)
        }
        ToolbarItemGroup {
            TextField("You", text: $view.you).frame(width: 90).help("Your name as a human in the tracker")
            Picker("Agents", selection: $model.agentMode) {
                ForEach(SimulatorModel.AgentMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 180)
            Menu {
                Button("Load demo tickets") { Task { await model.loadDemo() } }
                Button("Add contradicting ticket (Fahrenheit)") { Task { await model.loadConflictingTicket() } }
                Button("Restart harness (reload from ledger)") { Task { await model.restartHarness() } }
                Button("Open workspace in Finder") { model.openWorkspace() }
                Divider()
                Button("Reset everything", role: .destructive) { Task { await model.reset() } }
            } label: { Label("Simulation", systemImage: "gearshape") }
        }
    }
}
