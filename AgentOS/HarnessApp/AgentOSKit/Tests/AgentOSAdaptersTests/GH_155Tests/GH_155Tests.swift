// Expected API: scripts/stamp-harness-build.sh <repo> <stamp.json> writes HEAD and
// a modified Bool; HarnessBuildStamp.recordedBuild(from: URL?) throws -> HarnessBuild
// reads that stamp (missing means "unknown"), and .current reads the app stamp.
// RepositorySession accepts harnessBuild: HarnessBuild, defaulting to .current.
// Existing RunConfigurationParts and diagnosis actions exercise real session
// wiring without preparing or changing any git repository.
// Reviewer-only: criterion 1's Xcode build-phase wiring and criterion 4's
// docs/real-repo-mode.md explanation of the configuration record and its purpose.
@testable import AgentOSAdapters
import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSCore

@Suite
struct GH_155Tests {
    @Test(arguments: ["", " M tracked.swift\n", "M  staged.swift\n", "?? new.swift\n"])
    func stampingRecordsHEADAndWhetherTheBuildWorkingCopyIsModified(status: String) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try fixture.prepareGit(status: status)
        let stamp = fixture.directory.appending(path: "build.json")

        let result = try await withHangGuard("GH-155 build stamping") {
            try await ProcessRunner.run(
                "/bin/sh", [Self.stampingScript.path, fixture.repository.path, stamp.path],
                in: fixture.directory, log: fixture.directory.appending(path: "stamp.log"),
                environment: ["PATH": fixture.bin.path + ":/usr/bin:/bin"]
            )
        }

        try #require(result.status == 0, "\(result.output)")
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stamp)) as? [String: Any]
        )
        #expect(object["commit"] as? String == Fixture.commit)
        #expect(object["modified"] as? Bool == !status.isEmpty)
        let build = try HarnessBuildStamp.recordedBuild(from: stamp)
        Self.expectBuild(build, modified: !status.isEmpty)
    }

    @Test
    func anAbsentBuildStampIsUnknownInsteadOfUsingTheRepositoryBeingWorkedOn() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        #expect(try HarnessBuildStamp.recordedBuild(from: nil) == HarnessBuild(commit: nil, modified: false))
        #expect(try HarnessBuildStamp.recordedBuild(
            from: fixture.directory.appending(path: "absent.json")
        ) == HarnessBuild(commit: nil, modified: false))
    }

    @Test(arguments: [false, true])
    func everyRealRepoRunRecordsTheStampedHarnessBuildIncludingItsModifiedMarker(
        modified: Bool
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let stamp = fixture.directory.appending(path: "build.json")
        try JSONSerialization.data(withJSONObject: [
            "commit": Fixture.commit, "modified": modified,
        ]).write(to: stamp)
        let build = try HarnessBuildStamp.recordedBuild(from: stamp)
        let session = try fixture.session(harnessBuild: build)

        let records = try await fixture.diagnoseTwoNodes(in: session)
        let configurations = Self.configurations(in: records)
        Self.expectEveryStartedRunHasAConfiguration(records, configurations)
        try #require(configurations.count == 2)
        for configuration in configurations {
            Self.expectBuild(configuration.parts.harnessBuild, modified: modified)
            #expect(configuration.parts.harnessBuild.commit != Fixture.workedOnCommit,
                    "The work item's repository HEAD is not the harness build.")
        }
    }

    @Test
    func anUnstampedPackageSessionRecordsUnknownForEveryRun() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        #expect(HarnessBuildStamp.current == HarnessBuild(commit: nil, modified: false),
                "The swift test package has no app build stamp.")
        let session = try fixture.session()

        let records = try await fixture.diagnoseTwoNodes(in: session)
        let configurations = Self.configurations(in: records)
        Self.expectEveryStartedRunHasAConfiguration(records, configurations)
        try #require(configurations.count == 2)
        #expect(configurations.allSatisfy {
            $0.parts.harnessBuild == HarnessBuild(commit: nil, modified: false)
        })
    }

    @Test(arguments: ["1.0.114\n", "  1.0.116 \n"])
    func copilotVersionIsReadOnceAndRecordedForEveryRun(output: String) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try fixture.prepareCopilot(output: output)
        let session = try fixture.session(copilot: true)

        let records = try await fixture.diagnoseTwoNodes(in: session)
        #expect(try fixture.versionCalls() == 1, "Probe the runtime once per session, not once per run.")
        let configurations = Self.configurations(in: records)
        Self.expectEveryStartedRunHasAConfiguration(records, configurations)
        try #require(configurations.count == 2)
        for configuration in configurations {
            #expect(configuration.parts.agentRuntimeName == "copilot")
            #expect(configuration.parts.agentRuntimeVersion == output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test(arguments: [
        VersionFailure.commandFailed, .emptyOutput, .whitespaceOnly, .noVersion,
    ])
    func unavailableCopilotVersionsAreRecordedAsUnknownWithoutRetryingPerRun(
        failure: VersionFailure
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try fixture.prepareCopilot(output: failure.output, status: failure == .commandFailed ? 7 : 0)
        let session = try fixture.session(copilot: true)

        let records = try await fixture.diagnoseTwoNodes(in: session)
        #expect(try fixture.versionCalls() == 1)
        let configurations = Self.configurations(in: records)
        Self.expectEveryStartedRunHasAConfiguration(records, configurations)
        try #require(configurations.count == 2)
        for configuration in configurations {
            #expect(configuration.parts.agentRuntimeName == "copilot")
            #expect(configuration.parts.agentRuntimeVersion == "unknown")
        }
    }

    @Test
    func aNewSessionReadsItsOwnRuntimeVersionEvenWhenItReusesTheSameTeam() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try fixture.prepareCopilot(output: "1.0.114\n")
        let team = RepositorySession.copilotTeam(executable: fixture.copilot.path, policy: fixture.policy)
        let first = try fixture.session(team: team)
        let firstRecords = try await fixture.diagnoseTwoNodes(in: first)
        #expect(try fixture.versionCalls() == 1)

        try fixture.setVersion(output: "1.0.116\n", status: 0)
        let second = try fixture.session(team: team)
        let secondRecords = try await fixture.diagnoseTwoNodes(in: second)
        #expect(try fixture.versionCalls() == 2, "A process-global or team-global cache is not a session cache.")
        let firstConfigurations = Self.configurations(in: firstRecords)
        let secondConfigurations = Self.configurations(in: secondRecords)
        try #require(firstConfigurations.count == 2 && secondConfigurations.count == 2)
        #expect(firstConfigurations.allSatisfy { $0.parts.agentRuntimeVersion == "1.0.114" })
        #expect(secondConfigurations.allSatisfy { $0.parts.agentRuntimeVersion == "1.0.116" })
    }

    @Test
    func fixtureCommandsAndSessionDiagnosticsWorkAgainstExistingAPIs() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        try fixture.prepareGit(status: " M fixture.swift\n")
        try fixture.prepareCopilot(output: "1.0.114\n")
        let head = try await ProcessRunner.run(
            fixture.bin.appending(path: "git").path, ["rev-parse", "HEAD"],
            in: fixture.repository, log: fixture.directory.appending(path: "head-probe.log")
        )
        #expect(head.status == 0 && head.output == Fixture.commit + "\n", "\(head.output)")
        let status = try await ProcessRunner.run(
            fixture.bin.appending(path: "git").path, ["status", "--porcelain"],
            in: fixture.repository, log: fixture.directory.appending(path: "status-probe.log")
        )
        #expect(status.status == 0 && status.output == " M fixture.swift\n", "\(status.output)")
        let version = try await ProcessRunner.run(
            fixture.copilot.path, ["--version"], in: fixture.directory,
            log: fixture.directory.appending(path: "version-probe.log")
        )
        #expect(version.status == 0 && version.output == "1.0.114\n")
        #expect(try fixture.versionCalls() == 1)
        let records = try await fixture.diagnoseTwoNodes(in: fixture.session(copilot: true))
        #expect(records.filter {
            if case .diagnosisRecorded(_, let diagnosis) = $0.event.kind {
                return diagnosis.cause == "Fixture diagnosis" && diagnosis.nextStep == "Read the ticket"
            }
            return false
        }.count == 2, "The fixture must drive existing agent and ledger APIs successfully.")
        Self.expectEveryStartedRunHasAConfiguration(records, Self.configurations(in: records))
    }

    private static var stampingScript: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/stamp-harness-build.sh")
    }

    private static func expectBuild(_ build: HarnessBuild, modified: Bool) {
        #expect(build.commit == Fixture.commit)
        #expect(build.modified == modified)
    }

    private struct Configuration {
        let run: RunID
        let parts: RunConfigurationParts
    }

    private static func configurations(in records: [RecordedEvent]) -> [Configuration] {
        records.compactMap { record in
            guard case .runConfigurationRecorded(let run, _, let parts) = record.event.kind else {
                return nil
            }
            return Configuration(run: run, parts: parts)
        }
    }

    private static func expectEveryStartedRunHasAConfiguration(
        _ records: [RecordedEvent], _ configurations: [Configuration]
    ) {
        let runs = records.compactMap { record -> RunID? in
            if case .runStarted(let run, _) = record.event.kind { return run }
            return nil
        }
        #expect(runs.count == 2, "The fixture must actually start two runs.")
        #expect(configurations.count == runs.count, "Record exactly one initial configuration per run.")
        #expect(Set(configurations.map(\.run)) == Set(runs))
    }

    enum VersionFailure: Sendable {
        case commandFailed, emptyOutput, whitespaceOnly, noVersion
        var output: String {
            switch self {
            case .commandFailed: "1.0.114\n"
            case .emptyOutput: ""
            case .whitespaceOnly: " \n\t\n"
            case .noVersion: "No version available\n"
            }
        }
    }

    private struct FixtureDiagnoser: Diagnoser {
        func diagnose(_ request: DiagnosisRequest) async throws -> Diagnosis {
            Diagnosis(cause: "Fixture diagnosis", nextStep: "Read the ticket")
        }
    }

    private struct UnusedAgents: Decomposer, TestAuthor, Implementer {
        func proposeChildren(_ request: BreakdownRequest) async throws -> Breakdown {
            throw AgentFailure("GH-155 fixture unexpectedly invoked a decomposer")
        }
        func writeAcceptanceTests(_ task: AgentTask) async throws -> AgentReport {
            throw AgentFailure("GH-155 fixture unexpectedly invoked a test author")
        }
        func implement(_ task: AgentTask) async throws {
            throw AgentFailure("GH-155 fixture unexpectedly invoked an implementer")
        }
    }

    private final class Fixture: Sendable {
        static let commit = "92fe9f30a1b2c3d4e5f60718293a4b5c6d7e8f90"
        static let workedOnCommit = "aabbccddeeff00112233445566778899aabbccddee"
        let directory: URL
        let repository: URL
        let bin: URL
        let copilot: URL
        let config: RepoConfig
        let policy: EffectivePolicy

        init() throws {
            directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appending(path: "GH-155-\(UUID().uuidString)")
            repository = directory.appending(path: "repository")
            bin = directory.appending(path: "bin")
            copilot = bin.appending(path: "copilot")
            config = RepoConfig(
                test: .init(command: "true"),
                leafTests: .init(target: "FixtureTests", folder: "Tests/FixtureTests")
            )
            policy = EffectivePolicy.resolve(harness: HarnessSettings(), repo: config, defaultBranch: "main")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        }

        func prepareGit(status: String) throws {
            try (Self.commit + "\n").write(to: directory.appending(path: "head"), atomically: true, encoding: .utf8)
            try status.write(to: directory.appending(path: "status"), atomically: true, encoding: .utf8)
            try writeExecutable("""
                #!/bin/sh
                base="$(cd "$(dirname "$0")/.." && pwd)"
                if test "$1" = "-C"; then
                  test "$2" -ef "$base/repository" || exit 64
                  shift 2
                elif ! test . -ef "$base/repository"; then
                  printf 'Stamp must read the supplied build repository\\n' >&2; exit 64
                fi
                case "$*" in
                  *rev-parse*HEAD*) cat "$base/head" ;;
                  *status*--porcelain*) cat "$base/status" ;;
                  *) printf 'Unsupported read-only fixture git command: %s\\n' "$*" >&2; exit 64 ;;
                esac
                """, to: bin.appending(path: "git"))
        }

        func prepareCopilot(output: String, status: Int32 = 0) throws {
            try setVersion(output: output, status: status)
            try writeExecutable("""
                #!/bin/sh
                base="$(dirname "$0")/.."
                if test "$#" -eq 1 && test "$1" = "--version"; then
                  printf 'version\\n' >> "$base/version-calls"
                  cat "$base/version-output"
                  exit "$(cat "$base/version-status")"
                fi
                if test "$1" != "-p"; then
                  printf 'Unsupported fixture copilot command\\n' >&2; exit 64
                fi
                printf '%s\\n' '{"cause":"Fixture diagnosis","nextStep":"Read the ticket"}'
                """, to: copilot)
        }

        func setVersion(output: String, status: Int32) throws {
            try output.write(to: directory.appending(path: "version-output"), atomically: true, encoding: .utf8)
            try String(status).write(to: directory.appending(path: "version-status"), atomically: true, encoding: .utf8)
        }

        func versionCalls() throws -> Int {
            let file = directory.appending(path: "version-calls")
            guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
            return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count
        }

        func session(
            harnessBuild: HarnessBuild? = nil, copilot: Bool = false, team suppliedTeam: AgentTeam? = nil
        ) throws -> RepositorySession {
            var fallback = AgentTeam(
                name: "GH-155 fixture", decomposer: UnusedAgents(), testAuthor: UnusedAgents(),
                implementer: UnusedAgents()
            )
            fallback.diagnoser = FixtureDiagnoser()
            let team = suppliedTeam ?? (copilot
                ? RepositorySession.copilotTeam(executable: self.copilot.path, policy: policy) : fallback)
            let location = RepositoryLocation(
                root: repository, identity: "GH-155-fixture", branch: "main", commit: Self.workedOnCommit
            )
            let storage = directory.appending(path: "session-\(UUID().uuidString)")
            let ledger = try Ledger()
            let tracker = LocalTracker(project: "GH-155", store: nil)
            if let harnessBuild {
                return try RepositorySession(
                    location: location, storage: storage, ledger: ledger, config: config, policy: policy,
                    team: team, tracker: tracker, harnessBuild: harnessBuild
                )
            }
            return try RepositorySession(
                location: location, storage: storage, ledger: ledger, config: config, policy: policy,
                team: team, tracker: tracker
            )
        }

        func diagnoseTwoNodes(in session: RepositorySession) async throws -> [RecordedEvent] {
            try await withHangGuard("GH-155 real session diagnosis runs") {
                for index in 1...2 {
                    let id = "wn-GH-155-\(index)"
                    let spec = NodeSpec(
                        id: id, parent: nil, kind: .leaf, title: "Diagnose fixture \(index)",
                        intent: "Read a known escalation", acceptanceCriteria: ["Explain the escalation"]
                    )
                    try FileManager.default.createDirectory(
                        at: session.workspace.worktree(for: id), withIntermediateDirectories: true
                    )
                    try await session.ledger.append([
                        LedgerEvent(node: id, by: .human("Fixture owner"), kind: .nodeCreated(spec: spec, ticket: id)),
                        LedgerEvent(node: id, by: .reconciler, kind: .flagSet(.escalated, reason: "Fixture escalation")),
                    ])
                    let node = try #require(await session.ledger.workingState().nodes[id])
                    _ = try await session.reconciler.diagnose(node)
                }
                let records = await session.ledger.allRecords()
                #expect(records.filter {
                    if case .runFinished(_, let outcome) = $0.event.kind { return outcome == "diagnosed" }
                    return false
                }.count == 2)
                return records
            }
        }

        private func writeExecutable(_ contents: String, to file: URL) throws {
            try (contents + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }

        func removeFiles() {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Could not remove GH-155 fixture files: \(error)") }
        }
    }
}
