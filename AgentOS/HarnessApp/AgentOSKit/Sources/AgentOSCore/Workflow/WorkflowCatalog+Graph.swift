extension WorkflowCatalog {
    // Both landing strategies review the change; the guards retain their distinct ordering.
    static func logicalID(_ id: String) -> String {
        id == .batchMemberReview ? .singleChangeReview : id
    }

    static func flattenedStages(_ workflows: [WorkflowDefinition]) -> [WorkflowStage] {
        var result: [WorkflowStage] = []
        for var stage in workflows.flatMap(\.stages) {
            stage.id = logicalID(stage.id)
            if let index = result.firstIndex(where: { $0.id == stage.id }) {
                result[index].phases.formUnion(stage.phases)
                result[index].flags.formUnion(stage.flags)
                result[index].limits.formUnion(stage.limits)
                result[index].signals.formUnion(stage.signals)
            } else {
                result.append(stage)
            }
        }
        return result
    }

    static func flattenedTransitions(_ workflows: [WorkflowDefinition]) -> [WorkflowTransition] {
        var result: [WorkflowTransition] = []
        for var edge in workflows.flatMap(\.transitions) {
            edge.from = logicalID(edge.from)
            edge.to = logicalID(edge.to)
            if !result.contains(edge) { result.append(edge) }
        }
        return result
    }
}
