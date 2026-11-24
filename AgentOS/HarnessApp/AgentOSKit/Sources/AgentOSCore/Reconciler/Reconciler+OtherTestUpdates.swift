extension Reconciler {
    /// Shared boundary for test-author updates and verification of their locks. A person's approval waives
    /// the naming criterion (checked in review), never the test-area or protected-path restrictions.
    func allowedOtherTestUpdates(_ files: [String], of node: NodeState) -> [String] {
        let own = workspace.testFolder(for: node.spec)
        let areas = workspace.updatableTestAreas
        let candidates = Set(files.map { (file: String) -> String in
            var file = file
            while file.hasPrefix("./") { file.removeFirst(2) }
            while file.hasSuffix("/") { file.removeLast() }
            return file
        }).filter { file in
            // Never a whole area, the own folder or a folder holding it.
            areas.contains { !$0.isEmpty && file.hasPrefix($0) && file.count > $0.count }
                && file != own && !file.hasPrefix(own + "/") && !own.hasPrefix(file + "/")
                && !file.split(separator: "/").contains("..")
        }
        let protected = Set(policy.protectedPathViolations(Array(candidates)))
        return candidates.subtracting(protected).sorted()
    }
}
