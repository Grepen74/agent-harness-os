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
            Section("Always") {
                LabeledContent("Denied agent tools", value: HarnessSettings.deniedTools.joined(separator: ", "))
                LabeledContent("Protected paths", value: HarnessSettings.protectedPaths.joined(separator: ", "))
            }
            Button("Restore defaults") { model.settings = HarnessSettings() }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
