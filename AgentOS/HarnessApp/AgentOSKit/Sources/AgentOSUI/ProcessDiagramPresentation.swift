import AgentOSCore
import CoreGraphics

public enum ProcessSelection: Equatable {
    case stage(String)
    case transition(String)
}

/// Identifies a drawn stage card. A stage that both workflows share (Proven) is drawn once per
/// lane, narrowed to that lane's node kind, so a leaf's Proven is not mistaken for its parent's.
/// Card IDs are the catalog stage ID, or "<node kind>/<stage ID>" for a narrowed card.
struct ProcessStageKey: Hashable {
    static let perLaneStages: Set<WorkflowStageID> = [.proven]

    let stageID: WorkflowStageID
    let kind: NodeKind?

    init(stageID: WorkflowStageID, kind: NodeKind? = nil) {
        self.stageID = stageID
        self.kind = Self.perLaneStages.contains(stageID) ? kind : nil
    }

    init(_ id: String) {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2, let kind = NodeKind(rawValue: parts[0]), Self.perLaneStages.contains(parts[1]) {
            self.init(stageID: parts[1], kind: kind)
        } else {
            self.init(stageID: id)
        }
    }

    var id: String { kind.map { "\($0.rawValue)/\(stageID)" } ?? stageID }

    var title: String { ProcessStageWording.title(self) }

    func matches(_ node: NodeState, at stage: WorkflowStageID) -> Bool {
        stage == stageID && (kind == nil || node.spec.kind == kind)
    }
}

/// A policy-projected catalog with repository occupancy, never persisted to the ledger.
public struct ProcessDiagramPresentation {
    public let stages: [ProcessStagePresentation]
    public let transitions: [ProcessTransitionPresentation]
    /// Parent–child links: a requirement's children follow their own workflows and report back
    /// when proven. They are not transitions, so they are neither selectable nor in menus.
    let childLinks: [ProcessChildLink]
    /// The policy's landing batch size when it lands in batches, otherwise 1.
    let landingBatchSize: Int

    init(policy: EffectivePolicy, state: WorkingState, node: NodeState? = nil) {
        let catalog = WorkflowCatalog.standard
        let projection = WorkflowProjection.project(catalog: catalog, policy: policy, node: node)
        let current = state.nodes.keys.reduce(into: [NodeID: WorkflowStageID]()) { result, id in
            result[id] = catalog.currentStage(of: id, in: state)?.stage
        }
        let requirementKinds: Set<WorkflowKind> = [.composite, .rootOnly]
        let leafKinds: Set<WorkflowKind> = [.leaf, .rootLeaf]
        let requirementIDs = Set(catalog.workflows
            .filter { requirementKinds.contains($0.kind) }.flatMap(\.stages).map(\.id))
        let leafIDs = Set(catalog.workflows.filter { $0.kind == .leaf }.flatMap(\.stages).map(\.id))
        let laneKinds: [NodeKind] = node.map { [$0.spec.kind] } ?? [.composite, .leaf]
        let batchSize = projection.stages.contains { $0.id == .batchChecks } ? policy.policy.landingBatchSize : 1
        landingBatchSize = batchSize

        var cards = projection.stages.flatMap { stage -> [ProcessStagePresentation] in
            let keys = ProcessStageKey.perLaneStages.contains(stage.id)
                ? laneKinds.map { ProcessStageKey(stageID: stage.id, kind: $0) }
                : [ProcessStageKey(stageID: stage.id)]
            return keys.map { key in
                let nodeIDs = state.nodes.values.filter { node in
                    current[node.id].map { key.matches(node, at: $0) } ?? false
                }.map(\.id)
                let workflow: ProcessWorkflow = switch key.kind {
                case .leaf: .leaf
                case .composite: .requirement
                case nil: requirementIDs.contains(stage.id) ? .requirement
                    : leafIDs.contains(stage.id) ? .leaf : .recovery
                }
                return ProcessStagePresentation(
                    stage: stage, key: key, nodeIDs: Set(nodeIDs), workflow: workflow,
                    whatHappens: ProcessStageWording.description(stage.id, kind: key.kind, batchSize: batchSize))
            }
        }

        // An edge touching a per-lane stage is drawn in each lane whose workflows declare it. Only a
        // composite has children, so an edge from or to a stage with child workflows is the requirement's.
        let parentStages = Set(catalog.stages.filter { !$0.childWorkflows.isEmpty }.map(\.id))
        func declaringKinds(_ edge: WorkflowTransition) -> [NodeKind] {
            func declared(in kinds: Set<WorkflowKind>) -> Bool {
                catalog.workflows.contains { workflow in
                    kinds.contains(workflow.kind) && workflow.transitions.contains {
                        $0.from == edge.from && $0.to == edge.to && $0.reason == edge.reason
                    }
                }
            }
            let parentEdge = parentStages.contains(edge.from) || parentStages.contains(edge.to)
            return [(NodeKind.composite, requirementKinds), (NodeKind.leaf, leafKinds)]
                .filter { laneKinds.contains($0.0) && declared(in: $0.1) && !(parentEdge && $0.0 == .leaf) }
                .map { $0.0 }
        }
        let edges = projection.transitions.flatMap { edge -> [ProcessTransitionPresentation] in
            let perLane = ProcessStageKey.perLaneStages.contains(edge.from)
                || ProcessStageKey.perLaneStages.contains(edge.to)
            let kinds: [NodeKind?] = perLane ? declaringKinds(edge).nonEmpty(or: laneKinds) : [nil]
            return kinds.map { kind in
                let from = ProcessStageKey(stageID: edge.from, kind: kind).id
                let to = ProcessStageKey(stageID: edge.to, kind: kind).id
                return ProcessTransitionPresentation(id: "\(from):\(to):\(edge.reason)", from: from, to: to,
                                                     reason: edge.reason, condition: edge.condition)
            }
        }

        // The catalog lists a shared stage with the requirement's stages; in the Leaf lane its card
        // follows the last leaf stage that leads into it.
        for card in cards where card.key.kind == .leaf {
            guard let index = cards.firstIndex(where: { $0.id == card.id }) else { continue }
            cards.remove(at: index)
            let feeders = Set(edges.filter { $0.to == card.id }.map(\.from))
            let after = cards.lastIndex { $0.workflow == .leaf && feeders.contains($0.id) }
            cards.insert(card, at: after.map { $0 + 1 } ?? cards.endIndex)
        }
        transitions = edges

        let lanes = Dictionary(cards.map { ($0.id, $0.workflow) }, uniquingKeysWith: { first, _ in first })
        let links = projection.stages.flatMap { parent -> [ProcessChildLink] in
            parent.childWorkflows.sorted { $0.key.rawValue < $1.key.rawValue }.flatMap { kind, workflowKind in
                guard let entry = catalog.workflows.first(where: { $0.kind == workflowKind })?.entryStage else {
                    return [ProcessChildLink]()
                }
                return [
                    ProcessChildLink(from: parent.id, to: ProcessStageKey(stageID: entry, kind: kind).id,
                                     role: .startsChild),
                    ProcessChildLink(from: ProcessStageKey(stageID: .proven, kind: kind).id, to: parent.id,
                                     role: .reportsBack),
                ]
            }
        }.filter { lanes[$0.from] != nil && lanes[$0.to] != nil }
        // A child that starts in its parent's own lane (a nested requirement at Allow breakdown) would
        // need a dashed line back up the lane, which reads like a transition; the parent card says it instead.
        let sameLaneStarts = links.filter { $0.role == .startsChild && lanes[$0.from] == lanes[$0.to] }
        for link in sameLaneStarts {
            guard let index = cards.firstIndex(where: { $0.id == link.from }) else { continue }
            cards[index].childNote = "Bigger children start this lane again at "
                + ProcessStageWording.title(ProcessStageKey(link.to).stageID) + "."
        }
        childLinks = links.filter { !sameLaneStarts.contains($0) }
        stages = cards
    }

    /// Recovery edges reach most stages, so drawing them all would bury the main workflows.
    /// They are drawn only for a selected Recovery transition or a selected stage at either end;
    /// every stage's outgoing-transitions menu still lists them.
    func drawnTransitions(for selection: ProcessSelection?) -> [ProcessTransitionPresentation] {
        let recovery = Set(stages.filter { $0.workflow == .recovery }.map(\.id))
        return transitions.filter { edge in
            guard recovery.contains(edge.from) || recovery.contains(edge.to) else { return true }
            switch selection {
            case .transition(let id): return id == edge.id
            case .stage(let id): return id == edge.from || id == edge.to
            case nil: return false
            }
        }
    }
}

enum ProcessWorkflow: String, CaseIterable {
    case requirement = "Requirement", leaf = "Leaf", recovery = "Recovery"
}

public struct ProcessStagePresentation: Identifiable {
    let stage: WorkflowStage
    let key: ProcessStageKey
    let workflow: ProcessWorkflow
    public let nodeIDs: Set<NodeID>
    /// One or two plain sentences on what happens here, for selection details and hover help.
    let whatHappens: String
    /// Where children that stay in this lane start, in place of a dashed link within the lane.
    var childNote: String?
    /// The card ID; differs from the catalog stage ID for a per-lane card such as "leaf/proven".
    public var id: String { key.id }
    public var waitsOnPerson: Bool { stage.actor == .person }
    public var waitingNodeIDs: Set<NodeID> { waitsOnPerson ? nodeIDs : [] }

    init(stage: WorkflowStage, key: ProcessStageKey, nodeIDs: Set<NodeID>, workflow: ProcessWorkflow,
         whatHappens: String) {
        self.stage = stage
        self.key = key
        self.nodeIDs = nodeIDs
        self.workflow = workflow
        self.whatHappens = whatHappens
    }

    public var title: String { ProcessStageWording.title(stage.id) }

    /// The title outside its lane (menus, selection details): "Proven (leaf)" for a per-lane card.
    var qualifiedTitle: String { ProcessStageWording.title(key) }

    var actor: String {
        switch stage.actor {
        case .agent(let role): "Agent: \(role.title)"
        case .reviewer: "Reviewer"
        case .person: "Person"
        case .harness: "Harness"
        }
    }

    var nodeCount: String { "\(nodeIDs.count) \(nodeIDs.count == 1 ? "node" : "nodes")" }
    var waitingCount: String { "\(waitingNodeIDs.count) waiting on a person" }
}

struct ProcessChildLink: Hashable {
    enum Role: Hashable { case startsChild, reportsBack }

    let from: String
    let to: String
    /// `startsChild`: the parent stage starts a child workflow; `reportsBack`: a proven child returns to it.
    let role: Role

    /// An entry and a return meet at the parent stage. The return comes in below the card's middle
    /// and the entry leaves above it, each on its own rail, so the two never join into one line
    /// (which would read as a path from Proven onwards).
    var route: (offset: CGFloat, verticalOffset: CGFloat) {
        switch role {
        case .reportsBack: (ProcessEdgeRoute.parallelOffset, ProcessEdgeRoute.parallelOffset)
        case .startsChild: (2 * ProcessEdgeRoute.parallelOffset, -ProcessEdgeRoute.parallelOffset)
        }
    }
}

struct ProcessStageMarker: Equatable {
    /// The stage clicked in the Process view: accent border.
    let selected: Bool
    /// Where the node selected in Work currently is: badge and dashed border.
    let nodeLocation: Bool
}

private extension Array {
    func nonEmpty(or fallback: Self) -> Self { isEmpty ? fallback : self }
}

public struct ProcessTransitionPresentation: Identifiable {
    public let id: String
    public let from: String
    public let to: String
    public let reason: String
    public let condition: String
}

extension HarnessViewModel {
    public var processDiagram: ProcessDiagramPresentation {
        ProcessDiagramPresentation(
            policy: processPolicy, state: state, node: selectedNodeID.flatMap { state.nodes[$0] })
    }
}
