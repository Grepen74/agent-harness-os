import AgentOSCore
import Observation
import SwiftUI

/// The harness settings: the outer limits for every repo on this Mac, kept in UserDefaults.
@Observable @MainActor
final class SettingsModel {
    private static let key = "harnessSettings"

    var settings: HarnessSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
        }
    }

    init() {
        settings = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(HarnessSettings.self, from: $0) } ?? HarnessSettings()
    }
}

struct SettingsView: View {
    @Environment(SettingsModel.self) private var model
    @State private var offeredModels = ""
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Landing branch", text: $model.settings.landingBranch)
                LabeledContent("Push / open pull requests", value: "Never")
            } footer: {
                Text("Proven work lands on this local branch. You review, merge and push it yourself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Limits a repo may lower, never raise") {
                Stepper("Max attempts per leaf: \(model.settings.maxAttempts)", value: $model.settings.maxAttempts, in: 1...10)
                Stepper("Max reworks per leaf: \(model.settings.maxReworks)", value: $model.settings.maxReworks, in: 1...10)
                Stepper("Max parallel agents: \(model.settings.maxParallelAgents)", value: $model.settings.maxParallelAgents, in: 1...8)
            }
            Section("Signals offered (a repo may switch them off)") {
                ForEach(HarnessCommand.allCases, id: \.self) { command in
                    Toggle("harness:\(command.rawValue)", isOn: Binding(
                        get: { model.settings.offeredSignals.contains(command) },
                        set: { if $0 { model.settings.offeredSignals.insert(command) } else { model.settings.offeredSignals.remove(command) } }))
                }
            }
            Section {
                TextField("Offered models", text: $offeredModels)
                    .onSubmit {
                        model.settings.offeredModels = offeredModels.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                    .onAppear { offeredModels = model.settings.offeredModels.joined(separator: ", ") }
                    .onChange(of: model.settings.offeredModels) { _, new in offeredModels = new.joined(separator: ", ") }
                ForEach(AgentModels.roles, id: \.self) { role in
                    Picker("\(role.job) agent", selection: Binding(
                        get: { model.settings.models[role] ?? "" },
                        set: { model.settings.models[role] = $0.isEmpty ? nil : $0 })) {
                        Text("Default model").tag("")
                        ForEach(modelChoices(for: role), id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                Text("Agents: \(HarnessSettings.agentProvider)")
            } footer: {
                Text("Comma-separated model names as the agent CLI knows them (`copilot --model`); press Return to apply. A repo may pick a model per role only among these.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Always") {
                LabeledContent("Denied agent tools", value: HarnessSettings.deniedTools.joined(separator: ", "))
                LabeledContent("Protected paths", value: HarnessSettings.protectedPaths.joined(separator: ", "))
            }
            Button("Restore defaults") { model.settings = HarnessSettings() }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    /// The offered models, plus the role's current pick if it's no longer offered (so the picker can show it).
    private func modelChoices(for role: AgentRole) -> [String] {
        let offered = model.settings.offeredModels
        guard let current = model.settings.models[role], !offered.contains(current) else { return offered }
        return offered + [current]
    }
}
