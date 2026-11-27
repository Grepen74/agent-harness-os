import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

extension GH_161Tests {
    struct Definition: Sendable {
        let ticket: String
        let id: NodeID
        let files: [String]?
        let suite: String?

        init(_ ticket: String, id: NodeID? = nil, files: [String]? = nil, suite: String? = nil) {
            self.ticket = ticket
            self.id = id ?? "wn-\(ticket)"
            self.files = files
            self.suite = suite
        }

        func spec(parent: NodeID?) -> NodeSpec {
            NodeSpec(id: id, parent: parent, kind: .leaf, title: ticket,
                     intent: "Preserve \(ticket) behavior", acceptanceCriteria: ["Behavior is correct"],
                     touches: ["Component-\(id)"])
        }

        func creationEvents(parent: NodeID?) -> [LedgerEvent] {
            var events = [LedgerEvent(node: id, by: .human("Developer"),
                                      kind: .nodeCreated(spec: spec(parent: parent), ticket: ticket))]
            if let files, let suite {
                events.append(LedgerEvent(node: id, by: .reconciler,
                                          kind: .testsRecorded(files: files, suite: suite)))
            }
            return events
        }
    }

    enum Ownership: String, CaseIterable, Sendable {
        case recordedFile, recordedSuite, trait, comment, legacyFolder, legacyFile

        func definition(_ ticket: String) -> Definition {
            switch self {
            case .recordedFile:
                Definition(ticket, files: ["Tests/Features/\(ticket)/ChecksSupport.swift"],
                           suite: "Feature_\(ticket.replacingOccurrences(of: "-", with: "_"))Tests")
            case .recordedSuite:
                Definition(ticket, files: ["Tests/Features/\(ticket)/Declaration.swift"],
                           suite: "Feature_\(ticket.replacingOccurrences(of: "-", with: "_"))Tests")
            default: Definition(ticket)
            }
        }

        func suite(for definition: Definition) -> String {
            switch self {
            case .recordedFile, .recordedSuite: definition.suite ?? "MissingRecordedSuite"
            case .trait, .comment: "Feature_\(definition.ticket.replacingOccurrences(of: "-", with: "_"))Tests"
            case .legacyFile, .legacyFolder: definition.spec(parent: nil).testTarget
            }
        }

        func location(for definition: Definition) -> CheckFailureLocation {
            let suite = suite(for: definition)
            switch self {
            case .recordedFile:
                return CheckFailureLocation(file: definition.files?.first, suite: nil)
            case .recordedSuite:
                return CheckFailureLocation(file: "Tests/Helpers/\(definition.ticket)/Assertions.swift", suite: suite)
            case .trait, .comment:
                return CheckFailureLocation(file: "Tests/Features/\(definition.ticket)/Declaration.swift", suite: suite)
            case .legacyFolder:
                return CheckFailureLocation(file: "Tests/\(suite)/Assertions.swift", suite: suite)
            case .legacyFile:
                return CheckFailureLocation(file: "Tests/Features/\(suite).swift", suite: suite)
            }
        }

        func sources(for definition: Definition) -> [String: String] {
            let suite = suite(for: definition)
            let declaration = "Tests/Features/\(definition.ticket)/Declaration.swift"
            switch self {
            case .trait:
                return [declaration: MarkerForm.trait.source(suite: suite, ticket: definition.ticket)]
            case .comment:
                return [declaration: MarkerForm.comment.source(suite: suite, ticket: definition.ticket)]
            case .recordedFile:
                return [definition.files?.first ?? declaration: "// Recorded assertion helper\n"]
            case .recordedSuite:
                return [declaration: "@Suite struct \(suite) {}\n"]
            case .legacyFolder:
                return ["Tests/\(suite)/Assertions.swift": "// Legacy assertion helper\n"]
            case .legacyFile:
                return ["Tests/Features/\(suite).swift": "@Suite struct \(suite) {}\n"]
            }
        }
    }

    enum Failure: Sendable {
        case none, own, proven, mixedOwnAndProven, mixedOwnAndUnknown, mixedUnknownAndProven, unknown, notProven, ambiguous
    }

    final class Fixture: Sendable {
        static let requirementID = "wn-GH-161-requirement"
        let root: URL
        let ids: [NodeID]
        let proven: [Definition]
        let ledger: Ledger
        let tracker: RecordingTracker
        let workspace: RecordingWorkspace
        let checks: RecordingChecks
        let reconciler: Reconciler

        init(count: Int, ownership: Ownership, failure: Failure) async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "GH-161-\(UUID())")
            let candidates = (0..<count).map { ownership.definition("GH-\(1610 + $0)") }
            ids = candidates.map(\.id)
            var established = [ownership.definition("GH-5"), ownership.definition("GH-53")]
            if failure == .ambiguous, let first = candidates.first {
                established[0] = Definition("GH-5", files: ownership.definition(first.ticket).files,
                                            suite: "ConflictingRecordTests")
            }
            proven = established
            let unproven = ownership.definition("GH-54")
            let all = candidates + proven + [unproven]
            ledger = try Ledger()
            tracker = RecordingTracker()
            workspace = RecordingWorkspace(root: root, ownership: ownership, definitions: all)
            checks = RecordingChecks(ownership: ownership, failure: failure, candidates: candidates,
                                     proven: proven, unproven: unproven, workspace: workspace)
            let unused = Unused()
            var policy = Policy(maxParallelAgents: 1, guesswork: .autonomous)
            policy.landingBatchSize = count == 1 ? 1 : 8
            policy.infrastructureRetryDelays = []
            reconciler = Reconciler(
                ledger: ledger, tracker: tracker, external: unused, workspace: workspace,
                artifacts: Artifacts(), checks: checks,
                team: AgentTeam(name: "GH-161", decomposer: unused, testAuthor: unused, implementer: unused),
                policy: policy
            )
            let requirement = NodeSpec(id: Self.requirementID, parent: nil, kind: .composite,
                                       title: "Landing attribution", intent: "Land candidates",
                                       acceptanceCriteria: ["Attributed failures reach their owners"])
            try await ledger.append([
                LedgerEvent(node: requirement.id, by: .human("Developer"),
                            kind: .nodeCreated(spec: requirement, ticket: "GH-161-REQ")),
                LedgerEvent(node: requirement.id, by: .reconciler, kind: .phaseChanged(to: .split)),
            ])
            for definition in proven {
                try await ledger.append(definition.creationEvents(parent: nil) + [
                    LedgerEvent(node: definition.id, by: .reconciler, kind: .landed(commit: "established-\(definition.id)")),
                    LedgerEvent(node: definition.id, by: .reconciler, kind: .phaseChanged(to: .proven)),
                ])
            }
            try await ledger.append(unproven.creationEvents(parent: nil) + [
                LedgerEvent(node: unproven.id, by: .reconciler,
                            kind: .flagSet(.escalated, reason: "Waiting for human guidance; harness:retry")),
            ])
            for definition in candidates {
                let spec = definition.spec(parent: requirement.id)
                try await workspace.seed(spec)
                let directory = workspace.worktree(for: spec.id)
                let digest = definition.files.map { Hashing.digest(ofRecordedFiles: $0, in: directory) }
                    ?? Hashing.digest(of: directory.appending(path: workspace.testFolder(for: spec)))
                let evidence = Evidence(
                    check: "own acceptance tests on branch", passed: true, summary: "Own tests passed",
                    specHash: spec.specHash, builtBy: "builder-\(spec.id)", checkedBy: "prechecker",
                    artifactPath: "precheck.log", artifactSHA256: Hashing.sha256(Data()),
                    commit: Self.commit(spec.id)
                )
                try await ledger.append(definition.creationEvents(parent: requirement.id) + [
                    LedgerEvent(node: spec.id, by: .human("Developer"), kind: .gateOpened(.build)),
                    LedgerEvent(node: spec.id, by: .reconciler, kind: .testsFixed(digest: digest)),
                    LedgerEvent(node: spec.id, by: .agent(run: evidence.builtBy, role: .implementer),
                                kind: .changeSubmitted(run: evidence.builtBy, commit: evidence.commit)),
                    LedgerEvent(node: spec.id, by: .agent(run: evidence.checkedBy, role: .verifier),
                                kind: .evidenceRecorded(evidence)),
                    LedgerEvent(node: spec.id, by: .reconciler, kind: .phaseChanged(to: .landing)),
                ])
            }
        }

        static func commit(_ id: NodeID) -> String { "commit-\(id)" }

        func round() async throws {
            let report = try await withHangGuard("GH-161 landing round") {
                await self.reconciler.runRound(waitForAgents: true)
            }
            try #require(report.safeStop == nil, "\(report.safeStop ?? "")")
        }

        func originalBatch() async throws -> LandingBatchCheck {
            try #require(await ledger.allRecords().compactMap { $0.event.kind.landingBatchCheck }
                .first { $0.nodes == ids }, "The fixture must exercise a full landing batch")
        }

        func cleanUp() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Could not remove GH-161 fixture: \(error)") }
        }
    }

    actor RecordingChecks: CheckRunner {
        struct Call: Sendable {
            let nodes: [NodeID]
            let only: String?
        }
        let ownership: Ownership
        let failure: Failure
        let candidates: [Definition]
        let proven: [Definition]
        let unproven: Definition
        let workspace: RecordingWorkspace
        private(set) var calls: [Call] = []

        init(ownership: Ownership, failure: Failure, candidates: [Definition], proven: [Definition],
             unproven: Definition, workspace: RecordingWorkspace) {
            self.ownership = ownership
            self.failure = failure
            self.candidates = candidates
            self.proven = proven
            self.unproven = unproven
            self.workspace = workspace
        }

        func runChecks(in directory: URL, only testTarget: String?) async -> CheckOutput {
            let nodes: [NodeID]
            do { nodes = try await workspace.nodes(in: directory) }
            catch {
                Issue.record("Checks received an unknown fixture directory: \(error)")
                return CheckOutput(passed: false, summary: "Unknown fixture directory", log: "\(error)")
            }
            calls.append(Call(nodes: nodes, only: testTarget))
            let bad = candidates.enumerated().filter { $0.offset.isMultiple(of: 2) && nodes.contains($0.element.id) }
                .map(\.element)
            guard failure != .none, !bad.isEmpty else { return Self.pass }
            let unknown = CheckFailureLocation(file: "Tests/Features/Unowned.swift", suite: "UnownedTests")
            let locations: [CheckFailureLocation]
            switch failure {
            case .none: return Self.pass
            case .own, .ambiguous: locations = bad.map { ownership.location(for: $0) }
            case .proven: locations = proven.map { ownership.location(for: $0) }
            case .mixedOwnAndProven:
                locations = bad.map { ownership.location(for: $0) } + proven.map { ownership.location(for: $0) }
            case .mixedOwnAndUnknown:
                locations = bad.map { ownership.location(for: $0) } + [unknown]
            case .mixedUnknownAndProven:
                locations = [unknown] + proven.map { ownership.location(for: $0) }
            case .unknown: locations = [unknown]
            case .notProven: locations = [ownership.location(for: unproven)]
            }
            let selected = testTarget.map { target in locations.filter {
                reportedSuite($0) == target
            }} ?? locations
            guard !selected.isEmpty else { return Self.pass }
            return CheckOutput(
                passed: false, summary: "Candidate breaks acceptance behavior",
                log: selected.map {
                    "Test preservedBehavior() recorded an issue at \($0.file ?? "Unknown.swift"):10:1: Expectation failed"
                }.joined(separator: "\n"),
                failingTargets: Set(selected.compactMap { reportedSuite($0) }),
                failureLocations: selected
            )
        }

        private func reportedSuite(_ location: CheckFailureLocation) -> String? {
            if let suite = location.suite { return suite }
            if let definition = (candidates + proven + [unproven]).first(where: {
                $0.files?.contains(location.file ?? "") == true
            }) {
                return ownership.suite(for: definition)
            }
            return Self.inferredTarget(location.file)
        }

        private static func inferredTarget(_ file: String?) -> String? {
            guard let file else { return nil }
            let url = URL(fileURLWithPath: file)
            let name = url.deletingPathExtension().lastPathComponent
            if name.hasSuffix("Tests") { return name }
            let folder = url.deletingLastPathComponent().lastPathComponent
            return folder.hasSuffix("Tests") ? folder : nil
        }

        private static var pass: CheckOutput {
            CheckOutput(passed: true, summary: "All checks passed", log: "Test run with 3 tests passed.")
        }
    }

    actor RecordingTracker: TrackerAdapter {
        private var messages: [String: [String]] = [:]
        func pendingSignals() async -> [Signal] { [] }
        func ticket(_ key: String) async -> Ticket? { nil }
        func consume(_ signal: Signal, reply: String) async {}
        func createChildTicket(parent: String, spec: NodeSpec, by: Participant) async throws -> String {
            throw AgentFailure("Landing must not create tickets")
        }
        func comment(on key: String, _ text: String) async { messages[key, default: []].append(text) }
        func setStatus(of key: String, to status: String) async {}
        func comments(on key: String) -> [String] { messages[key, default: []] }
    }

    struct Artifacts: ArtifactStore {
        func put(named name: String, contents: Data) throws -> StoredArtifact {
            StoredArtifact(path: name, sha256: Hashing.sha256(contents))
        }
    }

    struct Unused: Decomposer, TestAuthor, AgentOSCore.Implementer, ExternalDependencySource {
        func deliveredKeys() async -> Set<String> { [] }
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("The fixture supplies its hierarchy")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("The fixture starts with fixed tests")
        }
        func implement(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("Landing must not start implementation")
        }
    }
}
