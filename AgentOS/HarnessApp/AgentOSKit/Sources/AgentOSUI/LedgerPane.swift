import AgentOSCore
import SwiftUI

/// The ledger: every decision and result, in order, hash-chained (doc 04 §7, doc 07).
public struct LedgerPane: View {
    @Environment(HarnessViewModel.self) private var model

    public init() {}

    public var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                PaneHeader(title: "Ledger", subtitle: "\(model.ledgerPage.totalCount) records. Append-only; the source of truth.")
                HStack {
                    Button("Verify chain") { Task { await model.verifyChain() } }
                    if model.offersLedgerDemo {
                        Button("Tamper (demo)", role: .destructive) { Task { await model.tamper() } }
                            .help("Edit one stored record on disk, as someone with database access might")
                        if model.chain?.isIntact == false {
                            Button("Restore backup") { Task { await model.restoreLedger() } }
                                .help("Put back the copy saved before the tamper and restart the harness")
                        }
                    }
                    Spacer()
                    if let chain = model.chain {
                        Label(chain.isIntact ? "Intact (\(chain.checked))" : "Broken at #\(chain.problem!.position)",
                              systemImage: chain.isIntact ? "lock.fill" : "lock.open.fill")
                            .foregroundStyle(chain.isIntact ? .green : .red)
                            .help(chain.problem?.reason ?? "Every record's hash matches and links to the one before")
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
                HStack {
                    Picker("Ticket", selection: Binding(
                        get: { model.ledgerPage.selectedNode },
                        set: { node in Task { await model.ledgerPage.selectNode(node) } }
                    )) {
                        Text("All tickets").tag(nil as NodeID?)
                        ForEach(model.ledgerPage.nodeIDs, id: \.self) { node in
                            Text(model.ledgerNodeLabel(node)).tag(node as NodeID?)
                        }
                    }
                    Picker("Event kind", selection: Binding(
                        get: { model.ledgerPage.selectedKind },
                        set: { kind in Task { await model.ledgerPage.selectKind(kind) } }
                    )) {
                        Text("All event kinds").tag(nil as LedgerEventKind?)
                        ForEach(model.ledgerPage.eventKinds, id: \.self) { kind in
                            Text(kind.rawValue).tag(kind as LedgerEventKind?)
                        }
                    }
                    Spacer()
                    if model.ledgerPage.canShowOlder {
                        Button("Show older") { Task { await model.ledgerPage.showOlder() } }
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 12).padding(.bottom, 6)
                List(model.ledgerPage.records) { record in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("#\(record.position)").monospaced().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                        Image(systemName: record.event.by.icon).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.event.kind.summary)
                                .lineLimit(record.event.kind.landingBatchCheck == nil ? 2 : nil)
                            let nodeName = record.event.node.map { model.ledgerNodeLabel($0) } ?? "–"
                            Text("\(record.event.by.label) · \(nodeName) · \(record.hash.prefix(10)) · \(record.event.at.ledgerStamp)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
                // Match offscreen height estimates to the two-line rows when paging and scrolling.
                .environment(\.defaultMinListRowHeight, 35)
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
