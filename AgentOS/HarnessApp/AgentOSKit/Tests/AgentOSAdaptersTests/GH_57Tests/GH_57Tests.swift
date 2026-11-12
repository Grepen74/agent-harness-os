// Expected API: the published Markdown files are the documentation interface. Their reference
// exposes full RepoConfig paths, accepted types/values, omission defaults and harness restrictions.
// Copyable JSON uses existing RepoConfig.parse(_:), .json and .knownKeys; no new production API is needed.
import AgentOSCore
import CryptoKit
import Foundation
import Testing

@Suite struct GH_57Tests {
    @Test
    func referenceCoversEverySupportedPathIncludingChecksModelsProjectsAndReview() throws {
        let rows = try reference()
        let expected = try supportedPaths()
        #expect(Set(rows.map(\.path)) == expected,
                "Document containers and nested fields, including all five review fields; do not invent keys.")
        #expect(rows.count == expected.count, "Each config path has one unambiguous reference entry.")
        let topLevelKeys = Set(rows.map {
            String($0.path.split(separator: ".")[0]).replacingOccurrences(of: "[]", with: "")
        })
        #expect(topLevelKeys == RepoConfig.knownKeys)
        for role in AgentModels.roles {
            #expect(expected.contains("agents.models.\(role.rawValue)"))
        }
        for path in ["review", "review.level", "review.areas", "review.instructions",
                     "review.maxRounds", "review.model", "checks[].name", "checks[].command",
                     "tracker.project.statusField", "tracker.project.statusMap"] {
            #expect(expected.contains(path))
            #expect(rows.contains { $0.path == path })
        }
    }

    @Test
    func everyEntryExplainsItsTypeOmissionAndRestrictionWithoutTreatingOpenValuesAsEnums() throws {
        let rows = try reference()
        for row in rows {
            #expect(!row.accepted.isEmpty, "Missing accepted type or values for \(row.path)")
            #expect(!row.omission.isEmpty, "Missing omission default or required status for \(row.path)")
            #expect(!row.restriction.isEmpty, "Missing harness restriction (or explicit none) for \(row.path)")
            #expect(!["-", "\u{2014}", "n/a", "tbd"].contains(row.omission))
            #expect(!["-", "\u{2014}", "tbd"].contains(row.restriction))
        }
        for path in ["build.prepare", "build.command", "test.command", "test.only",
                     "checks[].name", "checks[].command", "leafTests.target", "leafTests.folder",
                     "landing.branch", "tracker.repo", "tracker.project.owner",
                     "tracker.project.statusField", "review.instructions"] {
            let row = try entry(path, in: rows)
            #expect(row.accepted.contains("string"), "Describe \(path) as a string, not an exhaustive example list.")
            #expect(hasAny(row.text, ["command", "shell", "name", "path", "branch", "field", "owner", "suite", "target"]),
                    "Explain the string's meaning or constraints: \(path)")
        }
        for path in ["components", "protectedPaths", "agents.context", "agents.deny", "signals.disable", "checks"] {
            let row = try entry(path, in: rows)
            #expect(hasAny(row.accepted, ["array", "list", "[]"]), "Describe the collection type: \(path)")
            #expect(hasAny(row.text, ["path", "glob", "tool", "signal", "command", "object", "component", "check"]))
        }
        for path in ["tracker.project.statusMap", "review.areas"] {
            let row = try entry(path, in: rows)
            #expect(hasAny(row.accepted, ["map", "object", "dictionary"]))
            #expect(hasAny(row.text, ["status", "area", "path"]))
            #expect(hasAny(row.text, ["string", "level", "option"]))
        }
        for path in ["build", "test", "leafTests", "landing", "signals", "limits", "agents",
                     "agents.models", "tracker", "tracker.project", "review"] {
            #expect(try entry(path, in: rows).accepted.contains("object"), "Describe the container type: \(path)")
        }
        #expect(try entry("test.command", in: rows).omission.contains("required"))
        #expect(try entry("checks[].name", in: rows).omission.contains("required"))
        #expect(try entry("checks[].command", in: rows).omission.contains("required"))
        #expect(try entry("tracker.project.owner", in: rows).omission.contains("required"))
        #expect(try entry("tracker.project.number", in: rows).omission.contains("required"))
        #expect(hasAny(try entry("tracker.project.number", in: rows).accepted, ["integer", "int"]))
    }

    @Test
    func builtInDefaultsAreNotPresentedAsImmutableConfigurableCeilings() throws {
        let rows = try reference()
        let defaults = HarnessSettings()
        for (path, value) in [
            ("limits.maxAttempts", defaults.maxAttempts),
            ("limits.maxReworks", defaults.maxReworks),
            ("limits.maxParallelAgents", defaults.maxParallelAgents),
        ] {
            let row = try entry(path, in: rows)
            #expect(hasAny(row.accepted, ["integer", "int"]))
            #expect(row.omission.contains("\(value)"), "State the built-in default for \(path).")
            #expect(hasAny(row.omission, ["harness", "inherit"]))
            #expect(hasAny(row.restriction, ["current", "setting", "configured"]),
                    "The ceiling follows the current harness setting, not a hard-coded built-in default.")
            #expect(hasAny(row.restriction, ["1", "positive"]))
            #expect(hasAny(row.restriction, ["at most", "<=", "\u{2264}", "no greater", "not exceed", "lower", "ceiling"]))
        }
        let guesswork = try entry("agents.guesswork", in: rows)
        for value in Guesswork.allCases {
            #expect(guesswork.accepted.contains(value.rawValue))
        }
        #expect(guesswork.omission.contains(defaults.guesswork.rawValue))
        #expect(hasAny(guesswork.omission, ["harness", "inherit"]))
        #expect(guesswork.restriction.contains("strict"))
        for role in AgentModels.roles {
            let row = try entry("agents.models.\(role.rawValue)", in: rows)
            #expect(row.accepted.contains("string"))
            #expect(hasAny(row.omission, ["inherit", "harness"]))
            #expect(row.restriction.contains("offer"))
        }
        let signals = try entry("signals.disable", in: rows)
        #expect(hasAny(signals.omission, ["inherit", "none", "empty", "[]"]))
        #expect(signals.restriction.contains("harness"))
        #expect(hasAny(signals.restriction, ["disable", "off", "remove"]))
        let documentation = normalized(try read(Self.referencePath))
        #expect(documentation.contains("built-in"))
        #expect(documentation.contains("settings"))
        #expect(documentation.contains("cli"))
    }

    @Test
    func referencePreservesCommandContextLandingTrackerAndAdditiveSafetySemantics() throws {
        let rows = try reference()
        let documentation = normalized(try read(Self.referencePath))
        expectPassage(documentation, all: ["/bin/sh", "top", "fail"])
        expectPassage(documentation, all: ["prepare", "build", "test", "checks"])
        #expect(try entry("test.only", in: rows).text.contains("{suite}"))
        #expect(hasAny(try entry("test.only", in: rows).omission, ["all tests", "full test"]))
        #expect(hasAny(try entry("leafTests", in: rows).text, ["block", "required", "agents need"]))
        let context = try entry("agents.context", in: rows)
        #expect(context.text.contains("tracked"))
        #expect(context.text.contains("glob"))
        #expect(context.omission.contains("readme.md"))
        #expect(context.omission.contains("agents.md"))
        expectPassage(documentation, all: ["context", "unmatched", "warning"],
                      alternatives: [["context", "no match", "warning"], ["context", "match", "warn"]])
        let landing = try entry("landing.branch", in: rows)
        #expect(landing.omission.contains("agentos/main"))
        #expect(landing.text.contains("local"))
        #expect(landing.restriction.contains("default branch"))
        #expect(hasAny(landing.restriction, ["not", "never", "different", "separate", "cannot"]))
        for path in ["agents.deny", "protectedPaths"] {
            let row = try entry(path, in: rows)
            #expect(hasAny(row.text, ["add", "extend", "union"]))
            #expect(row.text.contains("harness"))
            #expect(hasAny(row.restriction, ["cannot remove", "can't remove", "not remove", "only add", "additive",
                                           "extend", "never remove", "not replace"]))
        }
        let tracker = try entry("tracker.type", in: rows)
        #expect(tracker.accepted.contains(RepoConfig.Tracker.local))
        #expect(tracker.accepted.contains(RepoConfig.Tracker.githubIssues))
        #expect(tracker.omission.contains("local"))
        #expect(try entry("tracker.repo", in: rows).omission.contains("origin"))
        #expect(try entry("tracker.project.statusField", in: rows).omission.contains("status"))
        #expect(hasAny(try entry("tracker.project", in: rows).omission, ["label", "no board", "none", "not configured"]))
        let statusMap = try entry("tracker.project.statusMap", in: rows)
        #expect(statusMap.text.contains("status"))
        #expect(hasAny(statusMap.text, ["empty string", "\"\"", "''"]))
        #expect(hasAny(statusMap.text, ["unchanged", "alone", "skip", "no update"]))
        #expect(hasAny(statusMap.omission, ["default", "backlog", "inherit"]))
        let review = try entry("review.level", in: rows)
        for level in ["none", "agent", "agent+human"] {
            #expect(review.accepted.contains(level))
        }
        #expect(review.restriction.contains("strict"))
        let reviewModel = try entry("review.model", in: rows)
        #expect(reviewModel.accepted.contains("string"))
        #expect(reviewModel.restriction.contains("offer"))
        let reviewRounds = try entry("review.maxRounds", in: rows)
        #expect(hasAny(reviewRounds.accepted, ["integer", "int"]))
        #expect(reviewRounds.omission.contains("2"))
    }

    @Test
    func docsExplainExactTokensMergeFragmentsAndMultiSignalSelection() throws {
        let documentation = normalized(try read(Self.referencePath))
        #expect(documentation.contains("override in repo config"))
        expectPassage(documentation, all: ["assume and report", "assume-and-report"])
        expectPassage(documentation, all: ["copy", "json"])
        expectPassage(documentation, all: ["merge", "preserv"],
                      alternatives: [["merge", "sibling"], ["merge", "not replace"]])
        expectPassage(documentation, all: ["signal", "multiple"],
                      alternatives: [["signal", "more than one"], ["signal", "multi-select"],
                                     ["signal", "several"]])
        #expect(documentation.contains("signals.disable"))
    }

    @Test
    func copyableFragmentsHaveFullPathsAndMergeWithoutLosingExistingConfig() throws {
        let examples = try configExamples()
        #expect(!examples.isEmpty, "Publish copyable JSON, not only prose.")
        let supported = try supportedPaths()
        let base = try object(Self.completeConfig)
        var examplePaths: Set<String> = []
        var hasMultipleSignals = false
        for example in examples {
            let paths = Self.paths(in: example)
            examplePaths.formUnion(paths)
            #expect(Set(example.keys).isSubset(of: RepoConfig.knownKeys))
            #expect(paths.isSubset(of: supported),
                    "Fragments need full paths and must not invent keys; supported review fields are valid.")
            let merged = Self.merge(example, into: base)
            let parsed = try RepoConfig.parse(Self.json(merged))
            #expect(parsed.unknownKeys.isEmpty)
            if let signals = example["signals"] as? [String: Any],
               let disabled = signals["disable"] as? [String], Set(disabled).count >= 2 {
                hasMultipleSignals = true
                let known = Set(RepoOverrideDefinitions.knownSignalTokens)
                #expect(disabled.allSatisfy {
                    known.contains($0.hasPrefix("harness:") ? String($0.dropFirst(8)) : $0)
                })
            }
            let encoded = try object(parsed.config.json)
            #expect(Self.paths(in: encoded).isSuperset(of: Self.paths(in: example, ignoringNulls: true)),
                    "Parsing a copyable fragment must not silently discard nested fields.")
            Self.expectPreservedSiblings(base: base, fragment: example, merged: encoded)
        }
        for path in ["agents.guesswork", "limits.maxAttempts", "limits.maxReworks",
                     "limits.maxParallelAgents", "agents.models", "signals.disable"] {
            #expect(examplePaths.contains(path), "Include a full-path copyable example for \(path).")
        }
        #expect(hasMultipleSignals, "Show at least one copyable override disabling more than one signal.")
    }

    @Test
    func documentationExplainsDraftInclusionIncompleteDraftsAndExplicitActivation() throws {
        let documentation = normalized(try read(Self.referencePath))
        expectPassage(documentation, all: ["draft", "chosen"],
                      alternatives: [["draft", "selected"], ["draft", "selection"]])
        expectPassage(documentation, all: ["test.command", "required"],
                      alternatives: [["test.command", "incomplete"], ["test.command", "missing"]])
        expectPassage(documentation, all: ["incomplete", "load"],
                      alternatives: [["incomplete", "valid"], ["incomplete", "run"],
                                     ["missing", "test.command", "load"]])
        expectPassage(documentation, all: ["create", "checkout"])
        expectPassage(documentation, all: ["select", "not", "writ"],
                      alternatives: [["choos", "not", "writ"], ["explicit", "create", "writ"],
                                     ["only", "create", "writ"]])
        expectPassage(documentation, all: ["commit", "rescan", "default branch"],
                      alternatives: [["commit", "rescan", "main"]])
        expectPassage(documentation, all: ["rescan", "restart"],
                      alternatives: [["rescan", "reload"], ["rescan", "activ"], ["rescan", "appl"]])
    }

    @Test
    func appReadmeIntroducesTheOverrideWorkflowAndLinksToTheFullReference() throws {
        let readme = normalized(try read("AgentOS/HarnessApp/README.md"))
        #expect(readme.contains("docs/real-repo-mode.md"))
        #expect(readme.contains("override in repo config"))
        #expect(readme.contains("assume-and-report"))
        expectPassage(readme, all: ["copy", "merge"],
                      alternatives: [["snippet", "merge"], ["fragment", "merge"]])
        expectPassage(readme, all: ["draft", "select"],
                      alternatives: [["draft", "choos"], ["draft", "override"]])
        expectPassage(readme, all: ["create", "checkout"])
        expectPassage(readme, all: ["commit", "rescan"])
    }

    @Test
    func conceptAndProtectedDocumentationAndRepoConfigStayByteForByteUnchanged() throws {
        for (path, expected) in Self.unchangedFiles {
            let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == expected, "GH-57 must not change \(path).")
        }
        #expect(!FileManager.default.fileExists(
            atPath: Self.root.appendingPathComponent(".github/copilot-instructions.md").path),
            "This file was absent before GH-57; do not add it as part of this documentation change.")
        let configDirectory = Self.root.appendingPathComponent(".agentos")
        let files = try FileManager.default.subpathsOfDirectory(atPath: configDirectory.path)
            .filter { !FileManager.default.fileExists(
                atPath: configDirectory.appendingPathComponent($0).path + "/") }
        #expect(Set(files) == ["config.json"], "No repository .agentos files may be added or removed.")
    }

    private struct Entry {
        let path: String
        let accepted: String
        let omission: String
        let restriction: String
        var text: String { [accepted, omission, restriction].joined(separator: " ") }
    }

    private static let referencePath = "AgentOS/HarnessApp/docs/real-repo-mode.md"
    private static var root: URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("AgentOS/HarnessApp/AgentOSKit/Package.swift").path
        ), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        return directory
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
    }

    private func reference() throws -> [Entry] {
        let lines = try read(Self.referencePath).components(separatedBy: .newlines)
        var columns: (key: Int, accepted: Int, omission: Int, restriction: Int)?
        var rows: [Entry] = []
        for line in lines {
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("|") else {
                columns = nil
                continue
            }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            let headers = cells.map(normalized)
            if let key = headers.firstIndex(where: {
                ["key", "key path", "config key", "config path", "field", "path", "key / field"].contains($0)
            }),
               let accepted = headers.firstIndex(where: { hasAny($0, ["type", "accepted", "allowed", "values"]) }),
               let omission = headers.firstIndex(where: { hasAny($0, ["default", "omission", "omitted", "required"]) }),
               let restriction = headers.indices.first(where: {
                   $0 != omission && hasAny(headers[$0], ["restriction", "harness", "limit"])
               }) {
                columns = (key, accepted, omission, restriction)
                continue
            }
            guard let columns,
                  [columns.key, columns.accepted, columns.omission, columns.restriction].allSatisfy(cells.indices.contains) else {
                continue
            }
            let path = cells[columns.key].replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "[*]", with: "[]")
            guard path.first?.isLetter == true else { continue }
            rows.append(Entry(path: path, accepted: normalized(cells[columns.accepted]),
                              omission: normalized(cells[columns.omission]),
                              restriction: normalized(cells[columns.restriction])))
        }
        #expect(!rows.isEmpty, "Publish a reference table with path, accepted type/values, omission and harness restriction columns.")
        return rows
    }

    private func entry(_ path: String, in rows: [Entry]) throws -> Entry {
        try #require(rows.first { $0.path == path }, "Missing reference entry: \(path)")
    }

    private func hasAny(_ text: String, _ alternatives: [String]) -> Bool {
        alternatives.contains { text.contains($0) }
    }

    private func expectPassage(_ text: String, all terms: [String], alternatives: [[String]] = []) {
        let passages = text.components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: " ") }
        #expect(([terms] + alternatives).contains { words in
            passages.contains { passage in words.allSatisfy { passage.contains($0) } }
        }, "Explain these related concepts together: \(terms.joined(separator: ", ")).")
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func supportedPaths() throws -> Set<String> {
        let config = try RepoConfig.parse(Self.completeConfig).config
        return Self.paths(in: try object(config.json))
    }

    private static func paths(
        in object: [String: Any], prefix: String = "", ignoringNulls: Bool = false
    ) -> Set<String> {
        var result: Set<String> = []
        for (key, value) in object {
            if ignoringNulls && value is NSNull { continue }
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            result.insert(path)
            if ["review.areas", "tracker.project.statusMap"].contains(path) { continue }
            if let nested = value as? [String: Any] {
                result.formUnion(paths(in: nested, prefix: path, ignoringNulls: ignoringNulls))
            } else if let entries = value as? [[String: Any]] {
                for entry in entries {
                    result.formUnion(paths(in: entry, prefix: path + "[]", ignoringNulls: ignoringNulls))
                }
            }
        }
        return result
    }

    private func configExamples() throws -> [[String: Any]] {
        var language: String?
        var body: [String] = []
        var examples: [[String: Any]] = []
        for line in try read(Self.referencePath).components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let current = language {
                    if current == "json" {
                        let example = try object(body.joined(separator: "\n"))
                        if !Set(example.keys).isDisjoint(with: RepoConfig.knownKeys) {
                            examples.append(example)
                        }
                    }
                    language = nil
                    body = []
                } else {
                    language = String(trimmed.dropFirst(3)).lowercased()
                }
            } else if language != nil {
                body.append(line)
            }
        }
        return examples
    }

    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func merge(_ fragment: [String: Any], into original: [String: Any]) -> [String: Any] {
        var result = original
        for (key, value) in fragment {
            if let nested = value as? [String: Any], let existing = result[key] as? [String: Any] {
                result[key] = merge(nested, into: existing)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func expectPreservedSiblings(base: [String: Any], fragment: [String: Any], merged: [String: Any]) {
        for (key, original) in base {
            if fragment[key] == nil {
                #expect(NSDictionary(dictionary: [key: original]).isEqual(to: [key: merged[key] ?? NSNull()]))
            } else if let baseObject = original as? [String: Any],
                      let fragmentObject = fragment[key] as? [String: Any],
                      let mergedObject = merged[key] as? [String: Any] {
                expectPreservedSiblings(base: baseObject, fragment: fragmentObject, merged: mergedObject)
            }
        }
    }

    private static let completeConfig = """
    {
      "build": {"prepare": "generate-project", "command": "build-app"},
      "test": {"command": "run-tests", "only": "--filter {suite}"},
      "checks": [{"name": "lint", "command": "run-lint"}],
      "leafTests": {"target": "AppTests", "folder": "Tests/AppTests"},
      "components": ["Sources/App"],
      "landing": {"branch": "agentos/main"},
      "signals": {"disable": ["go"]},
      "limits": {"maxAttempts": 2, "maxReworks": 2, "maxParallelAgents": 1},
      "agents": {
        "deny": ["custom-tool"],
        "models": {"decomposer": "model-a", "testAuthor": "model-b", "implementer": "model-c"},
        "guesswork": "ask", "context": ["README.md", "docs/*.md"]
      },
      "protectedPaths": ["Secrets/"],
      "tracker": {
        "type": "github-issues", "repo": "owner/repo",
        "project": {"owner": "owner", "number": 1, "statusField": "Status", "statusMap": {"Landing": ""}}
      },
      "review": {
        "level": "agent", "areas": {"Sources/App": "agent+human"},
        "instructions": "docs/review.md", "maxRounds": 2, "model": "review-model"
      }
    }
    """

    private static let unchangedFiles = [
        "00-overview.md": "e57cff55ef861fc11eb57086c131e27c6b410ada4ad295d0509793da11262f27",
        "01-repo-local-files.md": "fc8c184b42f32c6140b038e63a79327568d406cce5f78db0833be8c687a9ff57",
        "02-recursive-v-model.md": "6ddef977b243bb2de09c1cfece4b4c13bb9f92a8e5d4caaafc10a1abeccfdb7c",
        "03-tracker-adapters.md": "7d0203ba2cc0c8d26104304fee14b76b629859f326a139e1b0c19647b37489ad",
        "04-where-the-harness-lives.md": "0d6695cb07961301a5c61a78b3479115c6abb30907de9a67afd5c96a764ff58e",
        "05-starting-and-steering-work.md": "8bf75dbab00c3b7c1d668ee34c6c167596a160a5c5a5da884d9e52eefa02b753",
        "06-seeing-what-the-harness-is-doing.md": "a98132db54ae1d2449c49de31f001f1cb183a218d0462ecea73c33d7c0b1fea5",
        "07-the-reconciler.md": "803e86f964632e2f3ef24b8be1e5651f3612fac59c6f3199fa93103be791cb9c",
        "08-leaves-and-parallel-work.md": "72fb18122a778a50550a5dac1d3de0042c5e97592545e3de144508e15b9c2e39",
        "AGENTS.md": "60005ff2cbbe68281913c08261d5beb4c95fbfcbeba18914219b5c0257f321f6",
        ".agentos/config.json": "57bf663188602a6154cf93d8c1f6aad2748566342da7229f5b963084e28c236f",
    ]
}
