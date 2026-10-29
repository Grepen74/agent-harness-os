import Foundation
import Testing
import AgentOSAdapters
import AgentOSCore
@testable import AgentOSSimulation

/// Stands in for `swift test` so these tests run in milliseconds. It understands the scripted agents'
/// convention: evaluates every `#expect(Component.facts["key"] == "value")` in the test targets against the
/// facts in `Sources/<Component>/<Component>.swift`. The real runner is exercised by `swift run agentos demo`.
struct FakeCheckRunner: CheckRunner {
    func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
        let tests = directory.appending(path: "Tests")
        let targets = (try? FileManager.default.contentsOfDirectory(atPath: tests.path)) ?? []
        var failing: Set<String> = []
        for target in targets where testTarget == nil || target == testTarget {
            let file = tests.appending(path: "\(target)/\(target).swift")
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for match in text.matches(of: /#expect\((\w+)\.facts\["([^"]*)"\] == "([^"]*)"\)/) {
                let (component, key, value) = (String(match.output.1), String(match.output.2), String(match.output.3))
                let facts = ScriptedFacts.read(ScriptedFacts.sourceFile(component, in: directory))
                if facts[key]?.value != value { failing.insert(target) }
            }
        }
        return failing.isEmpty
            ? CheckOutput(passed: true, summary: "all tests passed", log: "ok")
            : CheckOutput(passed: false, summary: "\(failing.count) test target(s) failed", log: failing.sorted().joined(separator: "\n"),
                          failingTargets: failing)
    }
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "agentos-tests-\(UUID().uuidString)")
}

func makeSimulation(_ directory: URL = temporaryDirectory()) throws -> Simulation {
    try Simulation(directory: directory, team: .scripted, checks: FakeCheckRunner())
}

let alice = Participant.human("Alice")

extension Simulation {
    func signal(_ command: HarnessCommand, _ key: String, by who: Participant = alice) async {
        await tracker.addLabel(command.label, to: key, by: who)
        await runUntilIdle()
    }

    func node(_ key: String) async -> NodeState? { await ledger.workingState().node(forTicket: key) }
    func lastComment(_ key: String) async -> String { await tracker.ticket(key)?.comments.last?.text ?? "" }
}
