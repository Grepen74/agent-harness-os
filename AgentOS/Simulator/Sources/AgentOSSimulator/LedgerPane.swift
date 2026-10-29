import AgentOSCore
import SwiftUI

/// The ledger: every decision and result, in order, hash-chained (doc 04 §7, doc 07).
struct LedgerPane: View {
    @Environment(SimulatorModel.self) private var model

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                PaneHeader(title: "Ledger", subtitle: "\(model.records.count) records. Append-only; the source of truth.")
                HStack {
                    Button("Verify chain") { Task { await model.verifyChain() } }
                    Button("Tamper (demo)", role: .destructive) { Task { await model.tamper() } }
                        .help("Edit one stored record on disk, as someone with database access might")
                    Spacer()
                    if let chain = model.chain {
                        Label(chain.isIntact ? "Intact (\(chain.checked))" : "Broken at #\(chain.problem!.position)",
                              systemImage: chain.isIntact ? "lock.fill" : "lock.open.fill")
                            .foregroundStyle(chain.isIntact ? .green : .red)
                            .help(chain.problem?.reason ?? "Every record's hash matches and links to the one before")
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
                List(model.records.reversed()) { record in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("#\(record.position)").monospaced().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                        Image(systemName: record.event.by.icon).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.event.kind.summary).lineLimit(2)
                            Text("\(record.event.by.label) · \(record.event.node ?? "–") · \(record.hash.prefix(10))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            .frame(minHeight: 300)

            VStack(spacing: 0) {
                PaneHeader(title: "Harness activity", subtitle: "What each reconciler round did.")
                List(Array(model.activity.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
            .frame(minHeight: 140)
        }
    }
}
