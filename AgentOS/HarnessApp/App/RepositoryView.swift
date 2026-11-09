import AgentOSUI
import AppKit
import SwiftUI

/// A window for one real repo: the local tracker, the work tree, and the readiness findings, effective policy
/// and ledger in tabs. Step / Run start Copilot agents once nothing blocks them.
struct RepositoryView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case findings = "Readiness", policy = "Policy", ledger = "Ledger"
        var id: String { rawValue }
    }

    @State private var model: RepositoryModel
    @State private var tab = Tab.findings
    @Environment(SettingsModel.self) private var settings

    init(url: URL) { _model = State(initialValue: RepositoryModel(url: url)) }

    var body: some View {
        HSplitView {
            TrackerPane().frame(minWidth: 340, idealWidth: 400)
            WorkPane().frame(minWidth: 380, idealWidth: 460)
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                switch tab {
                case .findings: FindingsPane()
                case .policy: PolicyPane()
                case .ledger: LedgerPane()
                }
            }
            .frame(minWidth: 420, idealWidth: 520)
        }
        .environment(model.view)
        .frame(minWidth: 1200, minHeight: 600)
        .navigationTitle(model.name)
        .navigationSubtitle(model.url.path)
        .task {
            RecentRepositories.add(model.url)
            model.harness = settings.settings
            await model.rescan()
        }
        .onChange(of: settings.settings) { _, new in
            model.harness = new
            Task { await model.rescan() }
        }
        .onDisappear { model.close() }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                HStack(spacing: 0) {
                    Toggle(isOn: Binding(get: { model.isRunning }, set: { model.setRunning($0) })) {
                        Label(model.isRunning ? "Running" : "Stopped", systemImage: model.isRunning ? "pause.fill" : "play.fill")
                    }
                    .help("Run the reconciler continuously: agents pick up approved tickets")
                    .disabled(!model.canWork)
                    Button { Task { await model.step() } } label: { Label("Step", systemImage: "forward.frame") }
                        .help("Run exactly one reconciler round")
                        .disabled(!model.canWork || model.isRunning || model.isBusy)
                    ProgressView().controlSize(.small).opacity(model.showsActivity ? 1 : 0)
                    if !model.startBlockers.isEmpty {
                        Label("Agents blocked", systemImage: "hand.raised.fill")
                            .foregroundStyle(.orange)
                            .help("Agents can't start yet:\n" + model.startBlockers.map { "• \($0)" }.joined(separator: "\n"))
                    }
                }
                .padding(.horizontal, 12)
            }
            ToolbarItemGroup {
                HStack(spacing: 0) {
                    TextField("You", text: Binding(get: { model.view.you }, set: { model.view.you = $0 }))
                        .frame(width: 90).help("Your name as a human in the tracker")
                    Button { model.revealRepository() } label: { Label("Show repo in Finder", systemImage: "folder") }
                        .help("Show the repo in Finder")
                    Button { model.revealStorage() } label: { Label("Show harness data", systemImage: "externaldrive") }
                        .help("Show the harness's own data for this repo (outside the repo)")
                        .disabled(model.storage == nil)
                }
                .padding(.horizontal, 12)
            }
        }
    }
}
