import AgentOSCore
import AppKit
import SwiftUI

/// What applies to the repo (doc 04 §8): the harness's limits, tightened by the repo's config. Plus the checks
/// the config names, the baseline on the default branch, and a draft config when the repo has none.
public struct PolicyPane: View {
    @Environment(HarnessViewModel.self) private var model

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Policy", subtitle: "Harness settings are the limits; \(RepoConfig.path) may only tighten them.")
            List {
                if model.readiness != nil { configFile }
                if let policy = model.policy {
                    Section("Effective settings") {
                        ForEach(policy.settings) { SettingRow(setting: $0) }
                    }
                }
                if let config = model.config {
                    Section("Checks, in order") {
                        ForEach(Array(config.commands.enumerated()), id: \.offset) { _, command in
                            Text(command).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    Section("Baseline on \(model.readiness?.branch ?? "the default branch")") { baseline }
                } else if let draft = model.configDraft {
                    Section("Draft \(RepoConfig.path)") { DraftView(draft: draft) }
                } else if model.readiness != nil {
                    Section("No config") {
                        Text("Couldn't guess the build and test commands. Write \(RepoConfig.path) by hand.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var configFile: some View {
        let branch = model.readiness?.branch ?? "the default branch"
        let create = model.config == nil
        return Section("Config file") {
            HStack {
                Button(create ? "Create \(RepoConfig.path)" : "Open \(RepoConfig.path)") { model.openRepoConfig() }
                    .help(create ? "Write \(model.configDraft == nil ? "an empty config" : "the draft below") into your checkout and open it"
                                 : "Open the copy in your checkout in your default editor")
                Button("Rescan") { Task { await model.rescan() } }
                    .disabled(model.isScanning)
                    .help("Read the config on \(branch) again, after you've committed a change")
                Spacer()
            }
            Text("Edits the copy in your checkout. The harness reads the one committed on \(branch), so commit your change there.")
                .font(.caption).foregroundStyle(.secondary)
            if let pending = model.readiness?.findings.first(where: { $0.check == "checkout.config" }) {
                Label(pending.title + ". " + (pending.suggestion ?? ""), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var baseline: some View {
        HStack {
            Button("Run baseline") { Task { await model.runBaseline() } }
                .disabled(model.isRunningBaseline)
                .help("Run the configured checks on a clean export of the default branch")
            Button {} label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .help("A baseline records whether the default branch passes its configured checks, so agent changes can be compared against it.")
            ProgressView().controlSize(.small).opacity(model.isRunningBaseline ? 1 : 0)
            Spacer()
        }
        if let baseline = model.state.baseline {
            let current = baseline.commit == model.readiness?.commit
            Label("\(baseline.passed ? "Passed" : "Failed") at \(baseline.commit.prefix(8)) in \(baseline.seconds)s"
                  + (current ? "" : " (out of date)"),
                  systemImage: baseline.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(!current ? .orange : baseline.passed ? .green : .red)
            Text(baseline.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let log = baseline.log {
                Button("Show log") { model.open(log.path) }.buttonStyle(.link).font(.caption)
            }
        } else {
            Text("Runs the checks on a clean export of the default branch, outside your checkout. Can take minutes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SettingRow: View {
    let setting: EffectiveSetting

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(setting.name).font(.callout)
                Text(setting.value).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let note = setting.note {
                    Label(note, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(setting.source.rawValue)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(setting.source == .repo ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.15), in: Capsule())
                .help(setting.source == .repo ? "Set by \(RepoConfig.path)" : "The harness's setting (Settings window)")
        }
    }
}

private struct DraftView: View {
    let draft: String

    var body: some View {
        Text("Guessed from the scan. Check it, create it in your checkout, then commit it on the default branch yourself: "
             + "the harness writes it only when you ask, never commits it, and never edits the files that steer it.")
            .font(.caption).foregroundStyle(.secondary)
        Text(draft).font(.caption.monospaced()).textSelection(.enabled)
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(draft, forType: .string)
        }
    }
}
