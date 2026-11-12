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
    @State private var offeredReviewerModels = ""
    @State private var githubAccount = ""
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
                Picker("Guesswork", selection: $model.settings.guesswork) {
                    ForEach(Guesswork.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("""
                    How much agents may guess before asking. Questions about what users observe always stop the work. \
                    Ask: any assumption is a question too. Assume and report: assumptions are posted, and a leaf resting on \
                    them waits for you to see its tests before build. Autonomous: assumptions are posted, nothing waits.
                    """)
            }
            Section("Signals offered (a repo may switch them off)") {
                ForEach(HarnessCommand.allCases, id: \.self) { command in
                    Toggle("harness:\(command.rawValue)", isOn: Binding(
                        get: { model.settings.offeredSignals.contains(command) },
                        set: { if $0 { model.settings.offeredSignals.insert(command) } else { model.settings.offeredSignals.remove(command) } }))
                }
            }
            Section {
                Picker("Minimum review level", selection: $model.settings.review.level) {
                    ForEach(ReviewLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Reviewer", selection: Binding(
                    get: {
                        let reviewer = model.settings.review.reviewer
                        return reviewer.type == "default" ? "default" : reviewer.command == nil ? "model" : "command"
                    },
                    set: { choice in
                        model.settings.review.reviewer = ReviewerSelection(
                            type: choice == "default" ? "default" : "specific",
                            model: choice == "model" ? "" : nil,
                            command: choice == "command" ? "" : nil)
                    })) {
                    Text("Default").tag("default")
                    Text("Specific model").tag("model")
                    Text("Specific command").tag("command")
                }
                if model.settings.review.reviewer.type == "specific" {
                    if model.settings.review.reviewer.command != nil {
                        TextField("Reviewer command", text: Binding(
                            get: { model.settings.review.reviewer.command ?? "" },
                            set: { model.settings.review.reviewer.command = $0 }))
                    } else {
                        TextField("Reviewer model", text: Binding(
                            get: { model.settings.review.reviewer.model ?? "" },
                            set: { model.settings.review.reviewer.model = $0 }))
                    }
                }
                TextField("Offered reviewer models", text: $offeredReviewerModels)
                    .onSubmit {
                        model.settings.review.offeredModels = offeredReviewerModels.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                    .onAppear { offeredReviewerModels = model.settings.review.offeredModels.joined(separator: ", ") }
                    .onChange(of: model.settings.review.offeredModels) { _, models in
                        offeredReviewerModels = models.joined(separator: ", ")
                    }
            } header: {
                Text("Review")
            } footer: {
                Text("Default reviews with the first offered reviewer model that differs from the implementer's, or the agent CLI's default model if there's none. A repo may tighten review or choose an offered reviewer model. Commands receive the review prompt on stdin and return JSON with passed and findings. Separate offered models with commas; press Return to apply.")
                    .font(.caption).foregroundStyle(.secondary)
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
            Section {
                TextField("GitHub account", text: $githubAccount, prompt: Text("The active `gh` login"))
                    .onSubmit {
                        let account = githubAccount.trimmingCharacters(in: .whitespaces)
                        model.settings.githubAccount = account.isEmpty ? nil : account
                    }
                    .onAppear { githubAccount = model.settings.githubAccount ?? "" }
            } header: {
                Text("GitHub Issues")
            } footer: {
                Text("For repos whose config sets `\"tracker\": {\"type\": \"github-issues\"}`. The harness reads and writes issues as this `gh` login (`gh auth login`); agents never get its token. A Projects board in the config also needs the `project` scope (`gh auth refresh -s project`). Press Return to apply.")
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
