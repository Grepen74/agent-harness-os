import AgentOSCore
import SwiftUI

/// The readiness scan's findings (doc 01): blockers must be fixed before agents start, warnings can be accepted.
public struct FindingsPane: View {
    @Environment(HarnessViewModel.self) private var model

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Readiness", subtitle: subtitle)
            HStack {
                Button("Scan again") { Task { await model.rescan() } }.disabled(model.isScanning)
                ProgressView().controlSize(.small).opacity(model.isScanning ? 1 : 0)
                Spacer()
                if let scan = model.readiness {
                    Label(scan.isReady ? "Ready for agents" : "Not ready",
                          systemImage: scan.isReady ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(scan.isReady ? .green : .red)
                        .help(scan.isReady ? "No blockers. Warnings can be accepted." : "Fix the blockers before agents start work.")
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            List {
                ForEach(Finding.Severity.allCases, id: \.self) { severity in
                    let findings = model.readiness?.findings.filter { $0.severity == severity } ?? []
                    if !findings.isEmpty {
                        Section(severity.heading) {
                            ForEach(findings) { FindingRow(finding: $0) }
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        guard let scan = model.readiness else { return model.isScanning ? "Scanning…" : "Not scanned yet." }
        let at = scan.branch.map { "\($0) at \((scan.commit ?? "").prefix(8))" } ?? "no branch"
        return "\(at): \(scan.summary). Read-only: nothing in the repo is changed."
    }
}

private struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: finding.severity.icon).foregroundStyle(finding.severity.color).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title).font(.callout.weight(.medium))
                if !finding.detail.isEmpty {
                    Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                }
                if let suggestion = finding.suggestion {
                    Label(suggestion, systemImage: "arrow.turn.down.right").font(.caption)
                }
            }
            .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

extension Finding.Severity {
    var heading: String {
        switch self {
        case .blocker: "Blockers: agents can't work here safely yet"
        case .warning: "Warnings: agents can work, but likely badly"
        case .info: "Worth knowing"
        }
    }

    var icon: String {
        switch self {
        case .blocker: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .blocker: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}
