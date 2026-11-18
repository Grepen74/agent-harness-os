// GH-63: Detect the models your Copilot account offers, and the reasoning efforts each supports.

import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_63Tests {
    @Test
    func detectionListsTheModelsTheirEffortsAndTheDefaultWithoutAPrompt() async throws {
        let fake = try FakeACP()
        defer { fake.cleanup() }
        try fake.answer("initialize", ["protocolVersion": 1, "agentInfo": ["version": "9.9"]])
        try fake.answer("new", ["sessionId": "s1", "configOptions": [
            FakeACP.modelOption(current: "big"),
            FakeACP.effortOption(["low", "medium", "high"], current: "medium"),
        ]])
        try fake.answer("model-auto", ["configOptions": [FakeACP.modelOption(current: "auto")]])
        try fake.answer("model-small", ["configOptions": [
            FakeACP.modelOption(current: "small"), FakeACP.effortOption(["low", "medium", "ultra"], current: "low"),
        ]])
        // No answer for "plain": the CLI refuses to switch to it.
        let now = Date(timeIntervalSince1970: 1_000_000)

        let catalog = try await CopilotModelDetector(executable: fake.executable.path).detect(now: now)

        #expect(catalog.models.map(\.id) == ["auto", "big", "small", "plain"])
        #expect(catalog.defaultModel == "big")
        #expect(catalog.cliVersion == "9.9")
        #expect(catalog.detectedAt == now)
        let models = Dictionary(uniqueKeysWithValues: catalog.models.map { ($0.id, $0) })
        #expect(models["auto"]?.efforts == [])
        #expect(models["auto"]?.usage == "1x")
        #expect(models["big"]?.efforts == [.low, .medium, .high])
        #expect(models["big"]?.defaultEffort == .medium)
        #expect(models["big"]?.name == "Big model")
        #expect(models["small"]?.efforts == [.low, .medium])
        #expect(models["small"]?.enabled == false)
        #expect(models["plain"]?.efforts == nil)
        let requests = try fake.requests()
        #expect(!requests.contains { $0.contains("session/prompt") })
        #expect(!requests.contains { $0.contains("\"value\":\"big\"") })
    }

    @Test
    func aCLIWithoutAModelOptionOrASessionSaysSoClearly() async throws {
        let noModels = try FakeACP()
        defer { noModels.cleanup() }
        try noModels.answer("initialize", ["protocolVersion": 1])
        try noModels.answer("new", ["sessionId": "s1", "configOptions": [[String: Any]]()])
        let missing = await failure(of: CopilotModelDetector(executable: noModels.executable.path))
        #expect(missing.contains("didn't list its models"))

        let loggedOut = try FakeACP()
        defer { loggedOut.cleanup() }
        try loggedOut.answer("initialize", ["protocolVersion": 1])
        let refused = await failure(of: CopilotModelDetector(executable: loggedOut.executable.path))
        #expect(refused.contains("no new"))
        #expect(refused.contains("copilot login"))
    }

    @Test
    func aCLIThatExitsOrHangsIsReportedWithWhatItSaidAndStopped() async throws {
        let exits = try FakeACP(script: "#!/bin/sh\necho 'not logged in' >&2\nexit 1\n")
        defer { exits.cleanup() }
        let exited = await failure(of: CopilotModelDetector(executable: exits.executable.path))
        #expect(exited.contains("stopped before answering"))
        #expect(exited.contains("not logged in"))

        // The fake outlives the hang guard, so detection only ends in time if its timeout stops the CLI.
        let hangs = try FakeACP(script: "#!/bin/sh\necho 'still thinking' >&2\nexec sleep 600\n")
        defer { hangs.cleanup() }
        // Long enough for the fake to start and speak on a machine busy running the whole suite.
        let detector = CopilotModelDetector(executable: hangs.executable.path, timeout: .seconds(10))
        let hung = try await withHangGuard("Detection with a hanging CLI") { await failure(of: detector) }
        #expect(hung.contains("within"))
        #expect(hung.contains("still thinking"))
    }

    @Test
    func theCLIsOwnRequestsAreDeclinedSoItCarriesOn() async throws {
        let fake = try FakeACP()
        defer { fake.cleanup() }
        try fake.answer("initialize", ["protocolVersion": 1])
        try fake.ask(before: "new", [
            #"{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"fs/read_text_file","params":{}}"#,
        ])
        try fake.answer("new", ["sessionId": "s1", "configOptions": [FakeACP.modelOption(current: "auto")]])

        // The fake waits for each reply, so detection only finishes if both requests were answered.
        let catalog = try await CopilotModelDetector(executable: fake.executable.path, timeout: .seconds(600)).detect()

        #expect(catalog.defaultModel == "auto")
        let replies = try fake.replies()
        #expect(replies.count == 2)
        #expect(replies.first?.contains(#""id":"p1""#) == true)
        #expect(replies.first?.contains(#""outcome":"cancelled""#) == true)
        #expect(replies.last?.contains(#""id":7"#) == true)
        #expect(replies.last?.contains("-32601") == true)
    }

    @Test
    func cancellingDetectionStopsTheCLIPromptlyAndSaysNothing() async throws {
        // The fake and detection's own timeout both outlive the hang guard, so only cancelling can end it in time.
        let hangs = try FakeACP(script: "#!/bin/sh\necho $$ > \"$(dirname \"$0\")/pid\"\nexec sleep 600\n")
        defer { hangs.cleanup() }
        let detector = CopilotModelDetector(executable: hangs.executable.path, timeout: .seconds(600))
        let detection = Task { try await detector.detect() }
        let pidFile = hangs.directory.appending(path: "pid")
        try await eventually("The CLI starting") { FileManager.default.fileExists(atPath: pidFile.path) }

        detection.cancel()
        let result = try await withHangGuard("Cancelled detection") { await detection.result }

        #expect(throws: CancellationError.self) { try result.get() }
        let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
    }

    @Test
    func chosenModelsAreAddedOnceAndOfferedOnesNotDetectedAreFlagged() {
        #expect(ModelCatalog.adding(["b", "c", "c"], to: ["a", "b"]) == ["a", "b", "c"])
        let catalog = ModelCatalog(models: [.init(id: "a", name: "A")], detectedAt: .now)
        #expect(catalog.missing(from: ["a", "gone"]) == ["gone"])
    }

    @Test
    func theEffectivePolicyShowsWhenModelsWereDetectedAndWhatTheyDontSupport() {
        var harness = HarnessSettings()
        let undetected = EffectivePolicy.resolve(harness: harness, repo: nil, defaultBranch: "main")
        #expect(undetected.settings.first { $0.name == "Models detected" }?.value == "never")

        harness.offeredModels = ["big", "plain", "gone"]
        harness.models.testAuthor = "plain"
        harness.models.implementer = "gone"
        harness.efforts.decomposer = .high
        harness.efforts.testAuthor = .low
        harness.efforts.implementer = .medium
        harness.modelCatalog = ModelCatalog(models: [
            .init(id: "big", name: "Big", efforts: [.low, .medium]),
            .init(id: "plain", name: "Plain", efforts: []),
        ], detectedAt: .now, defaultModel: "big")
        let policy = EffectivePolicy.resolve(harness: harness, repo: nil, defaultBranch: "main")
        func note(_ name: String) -> String? { policy.settings.first { $0.name == name }?.note }

        #expect(policy.settings.first { $0.name == "Models detected" }?.value != "never")
        #expect(note("Breakdown reasoning effort")?.contains("big doesn't support high") == true)
        #expect(note("Acceptance tests reasoning effort")?.contains("plain doesn't support low") == true)
        #expect(note("Implementation reasoning effort") == nil)
        #expect(note("Implementation agent")?.contains("possibly unavailable") == true)
        #expect(note("Acceptance tests agent") == nil)
        #expect(policy.agentEfforts[.decomposer] == .high)
    }

    private func failure(of detector: CopilotModelDetector) async -> String {
        do {
            _ = try await detector.detect()
            return "no failure"
        } catch {
            return error.localizedDescription
        }
    }
}

/// A stand-in for `copilot --acp`: answers each JSON-RPC request with `<name>.json` from its folder, after a
/// notification, or with an error naming the missing answer. It writes each request to requests.log.
private struct FakeACP {
    let directory: URL
    var executable: URL { directory.appending(path: "copilot") }

    static let server = """
        #!/bin/sh
        dir="$(dirname "$0")"
        [ "$1" = "--acp" ] || exit 2
        exec 3<&0
        while IFS= read -r line <&3; do
          echo "$line" >> "$dir/requests.log"
          id="${line#*\\"id\\":}"; id="${id%%,*}"
          case "$line" in
            *'"method":"initialize"'*) answer=initialize ;;
            *'"method":"session/new"'*) answer=new ;;
            *'"method":"session/set_config_option"'*) value="${line#*\\"value\\":\\"}"; answer="model-${value%%\\"*}" ;;
            *) answer=unknown ;;
          esac
          echo '{"jsonrpc":"2.0","method":"session/update","params":{"update":{}}}'
          if [ -f "$dir/ask-$answer" ]; then
            while IFS= read -r ask; do
              echo "$ask"
              IFS= read -r reply <&3
              echo "$reply" >> "$dir/replies.log"
            done < "$dir/ask-$answer"
          fi
          if [ -f "$dir/$answer.json" ]; then
            sed "s/\\"__ID__\\"/$id/" "$dir/$answer.json"
          else
            echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":$id,\\"error\\":{\\"code\\":-32603,\\"message\\":\\"no $answer\\"}}"
          fi
        done
        """

    init(script: String = Self.server) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "agentos-GH-63-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func answer(_ name: String, _ result: [String: Any]) throws {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": "__ID__", "result": result]
        let data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        try (String(decoding: data, as: UTF8.self) + "\n").write(to: directory.appending(path: "\(name).json"),
                                                               atomically: true, encoding: .utf8)
    }

    func requests() throws -> [String] {
        try lines(of: "requests.log")
    }

    /// Before answering `name`, the fake sends these requests of its own and waits for a reply to each.
    func ask(before name: String, _ requests: [String]) throws {
        try requests.map { $0 + "\n" }.joined().write(to: directory.appending(path: "ask-\(name)"),
                                                      atomically: true, encoding: .utf8)
    }

    func replies() throws -> [String] {
        try lines(of: "replies.log")
    }

    private func lines(of file: String) throws -> [String] {
        try String(contentsOf: directory.appending(path: file), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    static func modelOption(current: String) -> [String: Any] {
        ["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": current, "options": [
            ["value": "auto", "name": "Auto", "description": "Let Copilot pick", "_meta": NSNull()],
            ["value": "auto", "name": "Auto", "_meta": ["copilotUsage": "1x", "copilotEnablement": "enabled"]],
            ["value": "big", "name": "Big model", "_meta": ["copilotUsage": "1x", "copilotEnablement": "enabled"]],
            ["group": "more", "name": "More", "options": [
                ["value": "small", "name": "Small model", "_meta": ["copilotEnablement": "disabled"]],
                ["value": "plain", "name": "Plain model"],
            ]],
        ]]
    }

    static func effortOption(_ levels: [String], current: String) -> [String: Any] {
        ["id": "reasoning_effort", "name": "Reasoning Effort", "category": "thought_level", "type": "select",
         "currentValue": current, "options": levels.map { ["value": $0, "name": $0] }]
    }
}
