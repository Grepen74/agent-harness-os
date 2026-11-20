import AgentOSAdapters
import AgentOSCore
import AgentOSUI
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
    @State private var detection: Task<Void, Never>?
    @State private var detected: ModelCatalog?
    @State private var detectionError: String?
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Requirement branch", value: "agentos/<ticket key>")
                PushPullRequestsToggle(settings: $model.settings)
            } footer: {
                Text("Off by default. A repo may switch publishing off, never on. Verified requirements wait In review until you merge them into main.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Limits a repo may lower, never raise") {
                Stepper("Max attempts per leaf: \(model.settings.maxAttempts)", value: $model.settings.maxAttempts, in: 1...10)
                Stepper("Max reworks per leaf: \(model.settings.maxReworks)", value: $model.settings.maxReworks, in: 1...10)
                Stepper("Max agent runs per ticket: \(model.settings.maxAgentRuns)", value: $model.settings.maxAgentRuns, in: 2...50)
                Stepper("Max parallel agents: \(model.settings.maxParallelAgents)", value: $model.settings.maxParallelAgents, in: 1...8)
                LandingBatchSizeStepper(settings: $model.settings)
                Picker("Guesswork", selection: $model.settings.guesswork) {
                    ForEach(Guesswork.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("""
                    How much agents may guess before asking. Questions about what users observe always stop the work. \
                    Ask: any assumption is a question too. Assume and report: assumptions are posted, and a leaf resting on \
                    them waits for you to see its tests before build. Autonomous: assumptions are posted, nothing waits.
                    """)
            }
            Section {
                AvoidOverlappingWorkToggle(settings: $model.settings)
            } footer: {
                Text("A repo may turn overlap avoidance on, but not off.")
                    .font(.caption).foregroundStyle(.secondary)
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
                possiblyUnavailable(model.settings.review.offeredModels)
            } header: {
                Text("Review")
            } footer: {
                Text("Default reviews with the first offered reviewer model that differs from the implementer's, or the agent CLI's default model if there's none. A repo may tighten review or choose an offered reviewer model. Commands receive the review prompt on stdin and return JSON with passed and findings. Separate offered models with commas; press Return to apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    HStack {
                        if detection != nil {
                            ProgressView().controlSize(.small)
                            Button("Cancel", action: cancelDetection)
                        } else {
                            Button("Detect models…", action: detectModels)
                        }
                    }
                } label: {
                    Text("Your account's models")
                    Text(model.settings.modelCatalog.map { "\($0.models.count) detected \($0.detectedDescription)" }
                         ?? "Never detected")
                }
                TextField("Offered models", text: $offeredModels)
                    .onSubmit {
                        model.settings.offeredModels = offeredModels.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                    .onAppear { offeredModels = model.settings.offeredModels.joined(separator: ", ") }
                    .onChange(of: model.settings.offeredModels) { _, new in offeredModels = new.joined(separator: ", ") }
                possiblyUnavailable(model.settings.offeredModels)
                ForEach(AgentModels.roles, id: \.self) { role in
                    Picker("\(role.job) agent", selection: Binding(
                        get: { model.settings.models[role] ?? "" },
                        set: { model.settings.models[role] = $0.isEmpty ? nil : $0 })) {
                        Text(model.settings.modelCatalog?.defaultModel.map { "Default model (\($0))" } ?? "Default model").tag("")
                        ForEach(modelChoices(for: role), id: \.self) { Text($0).tag($0) }
                    }
                    let supported = model.settings.modelCatalog?.efforts(for: model.settings.models[role])
                    Picker("\(role.job) reasoning effort", selection: Binding(
                        get: { model.settings.efforts[role] },
                        set: { model.settings.efforts[role] = $0 })) {
                        Text(defaultEffortTitle(for: role)).tag(ReasoningEffort?.none)
                        ForEach(effortChoices(for: role), id: \.self) { level in
                            Text(supported.map { $0.contains(level) } == false ? "\(level.rawValue) (not supported)" : level.rawValue)
                                .tag(Optional(level))
                        }
                    }
                    if let note = effortNote(for: role) {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                    timeoutStepper(role.title.capitalized, agent: role.rawValue)
                }
                timeoutStepper("Reviewer", agent: "reviewer")
                timeoutStepper("Diagnoser", agent: "diagnoser")
                Picker("Highest effort a repo may choose", selection: $model.settings.maxEffort) {
                    ForEach(ReasoningEffort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper("Longest timeout a repo may choose: \(model.settings.maxAgentTimeout / 60) min",
                        value: Binding(
                            get: { model.settings.maxAgentTimeout / 60 },
                            set: { minutes in
                                model.settings.maxAgentTimeout = minutes * 60
                                for (agent, seconds) in model.settings.agentTimeouts where seconds > minutes * 60 {
                                    model.settings.agentTimeouts[agent] = minutes * 60
                                }
                            }),
                        in: EffectivePolicy.timeoutRange.lowerBound / 60...EffectivePolicy.timeoutRange.upperBound / 60, step: 5)
            } header: {
                Text("Agents: \(HarnessSettings.agentProvider)")
            } footer: {
                Text("Detect models asks the Copilot CLI which models your account offers and which reasoning efforts each supports, without running a model; you choose what to offer. Or type comma-separated model names as the agent CLI knows them (`copilot --model`) and press Return. A repo may pick a model per role only among these. Reasoning effort is `copilot --reasoning-effort`: higher thinks harder but takes longer, so raise the role's timeout too. Once models are detected, each role offers only the efforts its model supports; a model that doesn't support the effort runs with the CLI's default effort. Default model and effort: the agent CLI's own settings. Timeouts stop an agent that runs longer; a repo may choose its own (`agents.timeouts`), up to the longest you allow.")
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
            Button("Restore defaults") {
                // The detected models aren't a setting: they stay.
                var defaults = HarnessSettings()
                defaults.modelCatalog = model.settings.modelCatalog
                model.settings = defaults
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400)
        .onDisappear(perform: cancelDetection)
        .sheet(isPresented: Binding(get: { detected != nil }, set: { if !$0 { detected = nil } })) {
            if let detected {
                DetectedModelsSheet(catalog: detected, offered: model.settings.offeredModels,
                                    offeredReviewers: model.settings.review.offeredModels) { agents, reviewers in
                    model.settings.offeredModels = ModelCatalog.adding(agents, to: model.settings.offeredModels)
                    model.settings.review.offeredModels = ModelCatalog.adding(reviewers, to: model.settings.review.offeredModels)
                    model.settings.modelCatalog = detected
                }
            }
        }
        .alert("Couldn't detect models", isPresented: Binding(get: { detectionError != nil },
                                                             set: { if !$0 { detectionError = nil } })) {
            Button("OK") { detectionError = nil }
        } message: {
            Text((detectionError ?? "") + "\n\nNothing changed.")
        }
    }

    private func detectModels() {
        guard let executable = CopilotCLI.locate() else {
            detectionError = "The Copilot CLI isn't installed: looked in /opt/homebrew/bin, /usr/local/bin and ~/.local/bin."
            return
        }
        detection = Task {
            do {
                let catalog = try await CopilotModelDetector(executable: executable).detect()
                if !Task.isCancelled { detected = catalog }
            } catch {
                if !Task.isCancelled, !(error is CancellationError) { detectionError = error.localizedDescription }
            }
            // A cancelled detection was already cleared, and a newer one may have started.
            if !Task.isCancelled { detection = nil }
        }
    }

    /// Stops a running detection; the CLI is stopped too, and nothing changes.
    private func cancelDetection() {
        detection?.cancel()
        detection = nil
    }

    /// Offered models that weren't among those last detected.
    @ViewBuilder private func possiblyUnavailable(_ offered: [String]) -> some View {
        if let catalog = model.settings.modelCatalog, case let missing = catalog.missing(from: offered), !missing.isEmpty {
            Text("Not among the models detected \(catalog.detectedDescription), so possibly unavailable: "
                 + missing.joined(separator: ", "))
                .font(.caption).foregroundStyle(.orange)
        }
    }

    /// The efforts the role's model supports once models are detected (all of them otherwise), plus the current one.
    private func effortChoices(for role: AgentRole) -> [ReasoningEffort] {
        let levels = model.settings.modelCatalog?.efforts(for: model.settings.models[role]) ?? ReasoningEffort.allCases
        guard let current = model.settings.efforts[role], !levels.contains(current) else { return levels }
        return (levels + [current]).sorted()
    }

    private func defaultEffortTitle(for role: AgentRole) -> String {
        let level = model.settings.modelCatalog?.model(model.settings.models[role])?.defaultEffort
        return level.map { "Default effort (\($0.rawValue))" } ?? "Default effort"
    }

    /// Minutes, in steps of 5, up to the longest timeout a repo may choose.
    private func timeoutStepper(_ title: String, agent: String) -> some View {
        let seconds = model.settings.agentTimeouts[agent] ?? EffectivePolicy.defaultAgentTimeouts[agent] ?? 1200
        return Stepper("\(title) timeout: \(seconds / 60) min", value: Binding(
            get: { seconds / 60 },
            set: { model.settings.agentTimeouts[agent] = $0 * 60 }),
            in: 1...max(1, model.settings.maxAgentTimeout / 60), step: 5)
    }

    private func effortNote(for role: AgentRole) -> String? {
        guard let catalog = model.settings.modelCatalog,
              let supported = catalog.efforts(for: model.settings.models[role]) else { return nil }
        let name = model.settings.models[role] ?? catalog.defaultModel ?? "The default model"
        if let effort = model.settings.efforts[role], !supported.contains(effort) {
            return "\(name) doesn't support \(effort.rawValue): it runs with the CLI's default effort."
        }
        return supported.isEmpty ? "\(name) has no reasoning effort setting." : nil
    }

    /// The offered models, plus the role's current pick if it's no longer offered (so the picker can show it).
    private func modelChoices(for role: AgentRole) -> [String] {
        let offered = model.settings.offeredModels
        guard let current = model.settings.models[role], !offered.contains(current) else { return offered }
        return offered + [current]
    }
}

/// The models Detect models found: choose which to offer to agents and reviewers. Nothing is saved until Save.
private struct DetectedModelsSheet: View {
    let catalog: ModelCatalog
    let offered: [String]
    let offeredReviewers: [String]
    let save: (_ agents: [String], _ reviewers: [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var agents: Set<String> = []
    @State private var reviewers: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models your Copilot account offers").font(.headline)
            Text("Detected \(catalog.detectedDescription). The CLI's default model: \(catalog.defaultModel ?? "unknown"). "
                 + "Choose which to offer; models already offered stay offered.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Agents")
                        Text("Reviewer")
                        Text("Model")
                        Text("Reasoning efforts")
                    }
                    .font(.caption.bold())
                    Divider()
                    ForEach(catalog.models) { model in
                        GridRow {
                            choice(model.id, in: $agents, offered: offered)
                            choice(model.id, in: $reviewers, offered: offeredReviewers)
                            VStack(alignment: .leading) {
                                Text(model.id).font(.body.monospaced())
                                Text([model.name, model.usage, model.details].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                                if !model.enabled {
                                    Text("Not enabled for your account").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Text(efforts(of: model)).font(.caption)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 380)
            let missing = catalog.missing(from: offered + offeredReviewers.filter { !offered.contains($0) })
            if !missing.isEmpty {
                Text("Offered but not detected, so possibly unavailable: \(missing.joined(separator: ", ")). "
                     + "They stay offered; remove them in Settings if they're gone.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let order = catalog.models.map(\.id)
                    save(order.filter(agents.contains), order.filter(reviewers.contains))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 640)
    }

    private func choice(_ id: String, in chosen: Binding<Set<String>>, offered: [String]) -> some View {
        Toggle(id, isOn: Binding(
            get: { offered.contains(id) || chosen.wrappedValue.contains(id) },
            set: { if $0 { chosen.wrappedValue.insert(id) } else { chosen.wrappedValue.remove(id) } }))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(offered.contains(id))
            .help(offered.contains(id) ? "Already offered" : "Offer \(id)")
    }

    private func efforts(of model: ModelCatalog.Model) -> String {
        guard let levels = model.efforts else { return "unknown" }
        guard !levels.isEmpty else { return "none" }
        return levels.map { $0 == model.defaultEffort ? "\($0.rawValue) (default)" : $0.rawValue }.joined(separator: ", ")
    }
}
