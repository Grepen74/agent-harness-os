import Foundation

extension Reconciler {
    /// Older runners expose only inferred targets. Explicit locations, when present, are authoritative.
    static func failureLocations(of output: CheckOutput) -> [CheckFailureLocation] {
        if !output.failureLocations.isEmpty { return output.failureLocations }
        return output.failingTargets.sorted().map { CheckFailureLocation(file: "\($0).swift", suite: $0) }
    }

    func failureSources(for outputs: [CheckOutput], among nodes: [NodeState],
                        in directory: URL) throws -> [String: String] {
        let needsMarkers = outputs.flatMap { Self.failureLocations(of: $0) }.contains { location in
            guard let suite = location.suite else { return false }
            return !nodes.contains { node in
                node.recordedTests?.suite == suite
                    || location.file.map { node.recordedTests?.files.contains($0) == true } == true
            }
        }
        guard needsMarkers else { return [:] }
        let root = directory.standardizedFileURL.path + "/"
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var sources: [String: String] = [:]
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.standardizedFileURL.path.hasPrefix(root) else { continue }
            sources[String(url.standardizedFileURL.path.dropFirst(root.count))] =
                try String(contentsOf: url, encoding: .utf8)
        }
        return sources
    }

    static func failureOwners(of output: CheckOutput, among nodes: [NodeState],
                              sources: [String: String]) -> [NodeState]? {
        let locations = failureLocations(of: output)
        guard !locations.isEmpty else { return nil }
        var ids: Set<NodeID> = []
        for location in locations {
            guard let owner = TestFailureAttribution.owner(of: location, among: nodes, sources: sources) else {
                return nil
            }
            ids.insert(owner)
        }
        return nodes.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
    }

    static func otherProvenFailureOwners(of output: CheckOutput, than node: NodeState,
                                        among nodes: [NodeState], sources: [String: String]) -> [NodeState]? {
        guard let owners = failureOwners(of: output, among: nodes, sources: sources),
              owners.allSatisfy({ $0.id != node.id && $0.phase == .proven }) else { return nil }
        return owners
    }

    static func hasOwnFailure(of output: CheckOutput, node: NodeState, among nodes: [NodeState],
                              sources: [String: String]) -> Bool {
        failureLocations(of: output).contains {
            TestFailureAttribution.owner(of: $0, among: nodes, sources: sources) == node.id
        }
    }

    static func failureSuites(of output: CheckOutput, among nodes: [NodeState],
                              sources: [String: String]) -> [String] {
        let suites = failureLocations(of: output).compactMap { location -> String? in
            if let suite = location.suite { return suite }
            guard let id = TestFailureAttribution.owner(of: location, among: nodes, sources: sources),
                  let node = nodes.first(where: { $0.id == id }) else { return nil }
            return node.recordedTests?.suite ?? node.spec.testTarget
        }
        return Set(suites).sorted()
    }
}
