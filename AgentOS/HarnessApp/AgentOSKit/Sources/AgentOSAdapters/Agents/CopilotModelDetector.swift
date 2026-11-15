import AgentOSCore
import Foundation

/// Asks the Copilot CLI which models the account offers and which reasoning efforts each supports, over the Agent
/// Client Protocol (`copilot --acp`). It opens one session in an empty temporary folder, switches its model through
/// each one to read the efforts, and sends no prompt, so no model runs and nothing is charged. The CLI keeps the
/// empty session in its history.
public struct CopilotModelDetector: Sendable {
    public var executable: String
    public var timeout: Duration

    public init(executable: String, timeout: Duration = .seconds(120)) {
        self.executable = executable
        self.timeout = timeout
    }

    /// Why detection didn't work, in words for the person who asked.
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    public func detect(now: Date = .now) async throws -> ModelCatalog {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agentos-models-\(UUID().uuidString)",
                                                                         directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process: LineProcess
        do {
            process = try LineProcess.start(executable, ["--acp"], in: directory, environment: ProcessRunner.toolEnvironment())
        } catch {
            throw Failure("Couldn't start the Copilot CLI (\(executable)): \(error.localizedDescription)")
        }
        let timeout = timeout
        do {
            let catalog = try await withThrowingTaskGroup(of: ModelCatalog?.self) { group in
                group.addTask { try await Self.converse(with: process, in: directory, now: now) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                guard let catalog = try await group.next() ?? nil else {
                    throw Failure("The Copilot CLI didn't list its models within \(timeout).")
                }
                return catalog
            }
            await process.stop()
            return catalog
        } catch {
            let errors = process.errorOutput()
            await process.stop()
            // Whoever cancelled detection doesn't want to hear why it stopped.
            if Task.isCancelled { throw CancellationError() }
            let message = (error as? Failure)?.message ?? "Detecting models failed: \(error.localizedDescription)"
            throw Failure(errors.isEmpty ? message : "\(message)\nThe CLI said: \(errors)")
        }
    }

    /// A JSON-RPC error the CLI answered with.
    private struct Refused: Error {
        let message: String
    }

    private static func converse(with process: LineProcess, in directory: URL, now: Date) async throws -> ModelCatalog {
        var lines = process.lines.makeAsyncIterator()
        var lastID = 0
        func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            lastID += 1
            let id = lastID
            let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes])
            do {
                try process.send(String(decoding: data, as: UTF8.self))
            } catch {
                throw Failure("The Copilot CLI stopped before answering \(method).")
            }
            // Notifications and the CLI's own requests come in between; only the answer to this request counts.
            while let line = await lines.next() {
                guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if let method = message["method"] as? String {
                    // The CLI waits for answers to its own requests: decline them, since detection does nothing.
                    if let requestID = message["id"], !(requestID is NSNull) {
                        try? process.send(Self.decline(method, id: requestID))
                    }
                    continue
                }
                guard (message["id"] as? Int) == id else { continue }
                if let error = message["error"] as? [String: Any] {
                    throw Refused(message: error["message"] as? String ?? "\(error)")
                }
                return message["result"] as? [String: Any] ?? [:]
            }
            try Task.checkCancellation()
            throw Failure("The Copilot CLI stopped before answering \(method).")
        }

        let initialized: [String: Any]
        let session: [String: Any]
        do {
            initialized = try await call("initialize", ["protocolVersion": 1, "clientCapabilities": [String: Any]()])
            session = try await call("session/new", ["cwd": directory.path, "mcpServers": [Any]()])
        } catch let refused as Refused {
            throw Failure("The Copilot CLI refused to start a session: \(refused.message). Is it logged in (`copilot login`)?")
        }
        guard let sessionID = session["sessionId"] as? String else {
            throw Failure("The Copilot CLI didn't start a session.")
        }
        let options = session["configOptions"] as? [[String: Any]] ?? []
        guard let modelOption = option(in: options, category: "model", id: "model"),
              let modelOptionID = modelOption["id"] as? String else {
            throw Failure("The Copilot CLI didn't list its models: its session has no model option. "
                + "An older CLI? `copilot update` gets the latest.")
        }
        let defaultModel = modelOption["currentValue"] as? String
        var efforts: [String: (levels: [ReasoningEffort]?, default: ReasoningEffort?)] = [:]
        if let defaultModel { efforts[defaultModel] = Self.efforts(in: options) }
        let choices = Self.choices(of: modelOption)
        for choice in choices where efforts[choice.value] == nil {
            do {
                let answer = try await call("session/set_config_option",
                                            ["sessionId": sessionID, "configId": modelOptionID, "value": choice.value])
                efforts[choice.value] = Self.efforts(in: answer["configOptions"] as? [[String: Any]] ?? [])
            } catch is Refused {
                efforts[choice.value] = (nil, nil)
            }
        }
        let version = (initialized["agentInfo"] as? [String: Any])?["version"] as? String
        return ModelCatalog(
            models: choices.map { choice in
                let meta = choice.meta
                return ModelCatalog.Model(
                    id: choice.value, name: choice.name, details: choice.description,
                    usage: meta["copilotUsage"] as? String,
                    enabled: (meta["copilotEnablement"] as? String).map { $0 == "enabled" } ?? true,
                    efforts: efforts[choice.value]?.levels, defaultEffort: efforts[choice.value]?.default)
            },
            detectedAt: now, defaultModel: defaultModel, cliVersion: version)
    }

    /// The answer to a request from the CLI: a permission request is cancelled, anything else is unknown here.
    static func decline(_ method: String, id: Any) -> String {
        var answer: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if method == "session/request_permission" {
            answer["result"] = ["outcome": ["outcome": "cancelled"]]
        } else {
            answer["error"] = ["code": -32601, "message": "Method not found: \(method)"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private struct Choice {
        let value: String
        let name: String
        let description: String?
        let meta: [String: Any]
    }

    private static func option(in options: [[String: Any]], category: String, id: String) -> [String: Any]? {
        options.first { $0["category"] as? String == category } ?? options.first { $0["id"] as? String == id }
    }

    /// A select option's values, flattening groups; a value listed twice keeps its first name and any details.
    private static func choices(of option: [String: Any]) -> [Choice] {
        let items = (option["options"] as? [[String: Any]] ?? []).flatMap { item in
            item["group"] != nil ? item["options"] as? [[String: Any]] ?? [] : [item]
        }
        var choices: [Choice] = []
        for item in items {
            guard let value = item["value"] as? String else { continue }
            let meta = item["_meta"] as? [String: Any] ?? [:]
            if let index = choices.firstIndex(where: { $0.value == value }) {
                if choices[index].meta.isEmpty, !meta.isEmpty {
                    let first = choices[index]
                    choices[index] = Choice(value: value, name: first.name, description: first.description, meta: meta)
                }
                continue
            }
            choices.append(Choice(value: value, name: item["name"] as? String ?? value,
                                  description: item["description"] as? String, meta: meta))
        }
        return choices
    }

    /// The reasoning efforts a session's options offer for its current model: none when it has no effort option.
    private static func efforts(in options: [[String: Any]]) -> (levels: [ReasoningEffort]?, default: ReasoningEffort?) {
        guard let effort = option(in: options, category: "thought_level", id: "reasoning_effort") else { return ([], nil) }
        let levels = choices(of: effort).compactMap { ReasoningEffort(rawValue: $0.value) }
        return (levels, (effort["currentValue"] as? String).flatMap(ReasoningEffort.init(rawValue:)))
    }
}
