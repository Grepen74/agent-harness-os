import AgentOSAdapters
import AgentOSCore
import Foundation

// Deterministic stand-ins for AI agents. They follow the same protocols and rules as real agents,
// so the harness can be exercised quickly and repeatably. The code they produce is deliberately
// trivial, but realistic enough to cause real merge conflicts and real regressions:
//
// Each component is one file holding the "facts" it provides, one line per fact, tagged with the node
// that added it. A criterion "Temperature unit: Celsius" becomes the fact "temperature unit" = "Celsius";
// other criteria become "<criterion>" = "yes".
//
//     public enum WeatherService {
//         public static let facts: [String: String] = [
//             "temperature unit": "Celsius",  // wn-APP-1.1
//         ]
//     }

enum ScriptedFacts {
    /// Splits off the optional touch hint at the end of a criterion: "… [WeatherService, WeatherUI]".
    static func touchHint(in criterion: String) -> (criterion: String, touches: [String]?) {
        guard let match = criterion.firstMatch(of: /\s*\[([^\]]+)\]\s*$/) else { return (criterion, nil) }
        return (String(criterion[..<match.range.lowerBound]),
                match.output.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    static func fact(for criterion: String) -> (key: String, value: String) {
        let criterion = touchHint(in: criterion).criterion
        let parts = criterion.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, !parts[1].isEmpty { return (parts[0].lowercased(), parts[1]) }
        return (criterion.lowercased(), "yes")
    }

    static func sourceFile(_ component: String, in directory: URL) -> URL {
        directory.appending(path: "Sources/\(component)/\(component).swift")
    }

    /// key → (value, node that added it)
    static func read(_ url: URL) -> [String: (value: String, node: String)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var facts: [String: (String, String)] = [:]
        for line in text.split(separator: "\n") {
            if let match = line.firstMatch(of: /^\s*"((?:[^"\\]|\\.)*)": "((?:[^"\\]|\\.)*)",\s*\/\/ (\S+)/) {
                facts[String(match.output.1)] = (String(match.output.2), String(match.output.3))
            }
        }
        return facts
    }

    static func write(_ facts: [String: (value: String, node: String)], component: String, to url: URL) throws {
        let lines = facts.keys.sorted().map { key in
            "        \(swiftLiteral(key)): \(swiftLiteral(facts[key]!.value)),  // \(facts[key]!.node)"
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        // Facts \(component) provides. Each line was added by an implementer run for the node at its end.
        public enum \(component) {
            public static let facts: [String: String] = [
        \(lines.joined(separator: "\n"))
            ]
        }

        """.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// One leaf per acceptance criterion. A criterion can name its touch set at the end, e.g.
/// "Temperature unit: Celsius [WeatherService, WeatherUI]"; otherwise the leaf touches one component named
/// after the parent. A leaf depends on an external item if its criterion mentions it.
public struct ScriptedDecomposer: Decomposer {
    public init() {}

    public func proposeChildren(of parent: NodeSpec, existingComponents: [String]) async throws -> [ChildProposal] {
        guard !parent.acceptanceCriteria.isEmpty else { throw AgentFailure("Nothing to break down: no acceptance criteria") }
        return parent.acceptanceCriteria.map { text in
            let (criterion, hinted) = ScriptedFacts.touchHint(in: text)
            let touches = hinted ?? [ComponentName.from(parent.title, maxWords: 3)]
            return ChildProposal(title: criterion, acceptanceCriteria: [criterion], touches: touches,
                                 dependsOn: parent.dependsOn.filter { text.contains($0) })
        }
    }
}

/// For every criterion, checks the fact in every touched component.
public struct ScriptedTestAuthor: TestAuthor {
    public init() {}

    public func writeAcceptanceTests(_ task: AgentTask) async throws {
        let target = task.spec.testTarget
        let tests = task.spec.acceptanceCriteria.enumerated().map { index, criterion in
            let fact = ScriptedFacts.fact(for: criterion)
            let expectations = task.spec.touches.map {
                "    #expect(\($0).facts[\(swiftLiteral(fact.key))] == \(swiftLiteral(fact.value)))"
            }
            return "@Test(\(swiftLiteral(criterion)))\nfunc criterion\(index + 1)() {\n\(expectations.joined(separator: "\n"))\n}"
        }
        let url = task.directory.appending(path: "Tests/\(target)/\(target).swift")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        // Acceptance tests for \(task.spec.id): \(task.spec.title)
        // Written by test author run \(task.run) before implementation. Nobody may change them afterwards.
        import Testing
        \(task.spec.touches.map { "import \($0)" }.joined(separator: "\n"))

        \(tests.joined(separator: "\n\n"))

        """.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Adds the node's facts to every touched component, keeping what's already there, unless told to
/// misbehave through a simulation hint:
/// - `sim:fail-once`: leaves out a criterion on the first attempt
/// - `sim:always-fail`: always leaves out a criterion (leads to escalation)
/// - `sim:stuck`: gives up without producing anything (no-progress detection)
public struct ScriptedImplementer: Implementer {
    public init() {}

    public func implement(_ task: AgentTask) async throws {
        if task.simulationHints.contains("sim:stuck") {
            throw AgentFailure("Agent gave up: couldn't make progress")
        }
        let defect = task.simulationHints.contains("sim:always-fail")
            || (task.simulationHints.contains("sim:fail-once") && task.attempt == 1)
        let criteria = defect ? Array(task.spec.acceptanceCriteria.dropFirst()) : task.spec.acceptanceCriteria
        for component in task.spec.touches {
            let url = ScriptedFacts.sourceFile(component, in: task.directory)
            var facts = ScriptedFacts.read(url)
            for criterion in criteria {
                let fact = ScriptedFacts.fact(for: criterion)
                facts[fact.key] = (fact.value, task.spec.id)
            }
            try ScriptedFacts.write(facts, component: component, to: url)
        }
    }
}

extension AgentTeam {
    public static let scripted = AgentTeam(
        name: "Scripted", decomposer: ScriptedDecomposer(), testAuthor: ScriptedTestAuthor(),
        implementer: ScriptedImplementer())
}
