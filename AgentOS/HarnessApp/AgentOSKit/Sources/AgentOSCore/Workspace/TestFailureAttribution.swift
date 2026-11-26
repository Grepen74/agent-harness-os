import Foundation

/// Resolves the first applicable ownership rule, never choosing between ambiguous owners.
public enum TestFailureAttribution {
    public static func owner(of location: CheckFailureLocation, among nodes: [NodeState],
                             sources: [String: String]) -> NodeID? {
        if let file = location.file {
            let recorded = nodes.filter { $0.recordedTests?.files.contains(file) == true }
            if !recorded.isEmpty { return unique(recorded) }
        }
        if let suite = location.suite {
            let recorded = nodes.filter { $0.recordedTests?.suite == suite }
            if !recorded.isEmpty { return unique(recorded) }
            let markers = sources.values.filter { $0.contains(suite) }.flatMap {
                SuiteTicketMarkers.markers(for: suite, in: $0)
            }
            if !markers.isEmpty {
                guard markers.count == 1 else { return nil }
                return unique(nodes.filter { $0.ticket == markers[0] })
            }
        }
        guard let file = location.file else { return nil }
        let parts = file.split(separator: "/").map(String.init)
        let basename = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        return unique(nodes.filter {
            $0.recordedTests == nil && (parts.dropLast().contains($0.spec.testTarget)
                || basename == $0.spec.testTarget)
        })
    }

    private static func unique(_ nodes: [NodeState]) -> NodeID? {
        nodes.count == 1 ? nodes[0].id : nil
    }
}
