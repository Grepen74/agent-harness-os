import AgentOSCore
import SwiftUI

/// Read-only workflows from the core catalog, with live repository counts.
public struct ProcessPane: View {
    @Environment(HarnessViewModel.self) private var model

    public init() {}

    public var body: some View {
        let diagram = model.processDiagram
        VStack(spacing: 0) {
            PaneHeader(title: "Process", subtitle: "Select a stage or an outgoing arrow for details. Nothing here changes the workflow.")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.policy == nil {
                        Text("No effective repository policy loaded; showing harness defaults.")
                            .foregroundStyle(.secondary)
                    }
                    selectionDetails(diagram)
                    if let selected = model.selectedNodeProcess {
                        ProcessSelectedNode(summary: selected)
                    }
                    ProcessLegend(batchSize: diagram.landingBatchSize)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 36) {
                            lane(.requirement, diagram: diagram).frame(minWidth: 280)
                            lane(.leaf, diagram: diagram).frame(minWidth: 280)
                        }
                        VStack(alignment: .leading, spacing: 24) {
                            lane(.requirement, diagram: diagram)
                            lane(.leaf, diagram: diagram)
                        }
                    }
                    lane(.recovery, diagram: diagram)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .backgroundPreferenceValue(ProcessStageAnchors.self) { anchors in
                    GeometryReader { geometry in
                        Canvas { context, _ in
                            for link in diagram.childLinks {
                                guard let source = anchors[link.from], let target = anchors[link.to] else { continue }
                                let route = ProcessEdgeRoute(from: geometry[source], to: geometry[target],
                                                             offset: link.route.offset,
                                                             verticalOffset: link.route.verticalOffset)
                                var path = Path()
                                path.addLines(route.points)
                                context.stroke(path, with: .color(.secondary.opacity(0.5)),
                                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                var arrow = Path()
                                arrow.addLines(route.arrowhead)
                                context.stroke(arrow, with: .color(.secondary), lineWidth: 1)
                            }
                            for edge in diagram.drawnTransitions(for: model.processSelection) {
                                guard let source = anchors[edge.from], let target = anchors[edge.to],
                                      edge.from != edge.to else { continue }
                                let route = ProcessEdgeRoute(from: geometry[source], to: geometry[target])
                                var path = Path()
                                path.addLines(route.points)
                                let selected = model.processSelection == .transition(edge.id)
                                context.stroke(path, with: .color(selected ? .accentColor : .secondary.opacity(0.3)),
                                               lineWidth: selected ? 2 : 1)
                                var arrow = Path()
                                arrow.addLines(route.arrowhead)
                                context.stroke(arrow, with: .color(.secondary), lineWidth: 1)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    private func lane(_ workflow: ProcessWorkflow, diagram: ProcessDiagramPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.rawValue).font(.title3.bold())
                Text(workflow.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(diagram.stages.filter { $0.workflow == workflow }) { stage in
                stageCard(stage, diagram: diagram)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.trailing, 14)
    }

    private func stageCard(_ stage: ProcessStagePresentation, diagram: ProcessDiagramPresentation) -> some View {
        let marker = model.processStageMarker(for: stage)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                model.processSelection = .stage(stage.id)
                model.workStageFilterID = stage.id
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(stage.title).font(.headline)
                        if marker.nodeLocation {
                            let interrupted = model.selectedNodeProcess?.interrupted == true
                            Label(interrupted ? "Interrupted" : "Selected node", systemImage: "location.fill")
                                .font(.caption).foregroundStyle(interrupted ? Color.orange : Color.secondary)
                        }
                        Spacer(minLength: 4)
                        if stage.waitsOnPerson {
                            Image(systemName: "person.fill").foregroundStyle(.orange)
                                .accessibilityLabel("Waiting on a person")
                        }
                    }
                    HStack {
                        Text(stage.nodeCount)
                        if !stage.waitingNodeIDs.isEmpty {
                            Text(stage.waitingCount).foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    if let note = stage.childNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(stage.whatHappens.isEmpty ? "Select for actor, limits and settings."
                  : stage.whatHappens + " Select for actor, limits and settings.")
            let edges = diagram.transitions.filter { $0.from == stage.id }
            if !edges.isEmpty {
                Menu {
                    ForEach(edges) { edge in
                        Button("\(title(edge.to, in: diagram)): \(edge.reason)") {
                            model.processSelection = .transition(edge.id)
                        }
                    }
                } label: {
                    Label("Outgoing transitions (\(edges.count))", systemImage: "arrow.turn.down.right")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if stage.waitsOnPerson {
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                    .fill(Color.orange).frame(width: 4)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            let shape = RoundedRectangle(cornerRadius: 8)
            if marker.selected {
                shape.stroke(Color.accentColor, lineWidth: 2)
            } else if marker.nodeLocation {
                shape.stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            } else {
                shape.stroke(Color.secondary.opacity(0.4), lineWidth: 1)
            }
        }
        .anchorPreference(key: ProcessStageAnchors.self, value: .bounds) { [stage.id: $0] }
    }

    @ViewBuilder private func selectionDetails(_ diagram: ProcessDiagramPresentation) -> some View {
        if let selection = model.processSelection {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Selection details").font(.headline)
                    Spacer()
                    Button("Clear selection") { model.processSelection = nil }
                }
                switch selection {
                case .stage(let id):
                    if let stage = diagram.stages.first(where: { $0.id == id }) {
                        Text(stage.qualifiedTitle).font(.title3.bold())
                        if !stage.whatHappens.isEmpty {
                            Text(stage.whatHappens).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Who acts: \(stage.actor)")
                        Text(stage.nodeCount)
                        if stage.waitsOnPerson {
                            Label("Waiting on a person", systemImage: "person.fill").foregroundStyle(.orange)
                            if !stage.waitingNodeIDs.isEmpty { Text(stage.waitingCount) }
                        }
                        if !stage.stage.condition.isEmpty { Text(stage.stage.condition) }
                        if !stage.stage.signals.isEmpty {
                            Text("Signals: " + stage.stage.signals.map(\.label).sorted().joined(separator: ", "))
                        }
                        Text("Loop limits and shaping settings").font(.headline)
                        if stage.stage.settings.isEmpty { Text("No additional settings or loop limits for this stage.") }
                        ForEach(stage.stage.settings.keys.sorted(), id: \.self) { key in
                            Text("\(key): \(stage.stage.settings[key] ?? "")").font(.body.monospaced())
                        }
                        if let policy = model.policy, stage.stage.retrySchedule != nil {
                            Text("infrastructureRetryDelays: " + stage.stage.retryDelays(in: policy.policy)
                                .map { "\($0)s" }.joined(separator: ", "))
                        }
                    } else {
                        Text("This stage is not present under the current effective policy. Clear the selection or choose another stage.")
                    }
                case .transition(let id):
                    if let edge = diagram.transitions.first(where: { $0.id == id }) {
                        Text("\(title(edge.from, in: diagram)) → \(title(edge.to, in: diagram))").font(.headline)
                        Text("Reason: \(edge.reason)").font(.title3)
                        Text("Condition: \(edge.condition)").font(.title3)
                    } else {
                        Text("This transition is not present under the current effective policy. Clear the selection or choose another transition.")
                    }
                }
            }
            .textSelection(.enabled)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func title(_ id: String, in diagram: ProcessDiagramPresentation) -> String {
        diagram.stages.first { $0.id == id }?.qualifiedTitle ?? id
    }
}

private struct ProcessStageAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
