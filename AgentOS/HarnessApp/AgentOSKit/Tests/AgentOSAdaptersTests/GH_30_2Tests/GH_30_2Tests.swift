// API contract: RepoConfig.Agents accepts optional repository-relative context paths or globs;
// RepositoryWorkspace.agentContext resolves them against tracked files and names the documents agents should read.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_30_2Tests {
    @Test
    func repoConfigAcceptsAgentContextPathsAndGlobs() throws {
        let parsed = try RepoConfig.parse(#"""
            {
              "test": {"command": "swift test"},
              "agents": {
                "context": ["docs/architecture.md", "docs/decisions/*.md"]
              }
            }
            """#).config

        #expect(parsed.agents?.context == [
            "docs/architecture.md",
            "docs/decisions/*.md",
        ])
    }

    @Test
    func agentPromptUsesDefaultOrConfiguredTrackedDesignDocuments() async throws {
        let defaultFixture = try await makeWorkspace(
            context: nil,
            trackedFiles: [
                "README.md": "# Product",
                "AGENTS.md": "Build and test conventions",
                "docs/architecture.md": "# Architecture",
            ]
        )
        defer { defaultFixture.cleanup() }

        #expect(defaultFixture.workspace.agentContext.contains("README.md"))
        #expect(defaultFixture.workspace.agentContext.contains("AGENTS.md"))
        #expect(!defaultFixture.workspace.agentContext.contains("docs/architecture.md"))

        let configuredFixture = try await makeWorkspace(
            context: ["docs/architecture.md", "docs/decisions/*.md"],
            trackedFiles: [
                "README.md": "# Product",
                "AGENTS.md": "Build and test conventions",
                "docs/architecture.md": "# Architecture",
                "docs/decisions/001-storage.md": "# Storage",
            ],
            untrackedFiles: [
                "docs/decisions/draft.md": "# Draft",
            ]
        )
        defer { configuredFixture.cleanup() }

        let context = configuredFixture.workspace.agentContext
        #expect(context.localizedCaseInsensitiveContains("read"))
        #expect(context.contains("where relevant"))
        #expect(context.contains("docs/architecture.md"))
        #expect(context.contains("docs/decisions/001-storage.md"))
        #expect(!context.contains("docs/decisions/draft.md"))
        #expect(!context.contains("README.md"))
        #expect(!context.contains("AGENTS.md"))
    }

    @Test
    func readinessWarnsForEveryMissingLiteralAndUnmatchedGlob() {
        let repo = snapshot(
            context: [
                "docs/missing-architecture.md",
                "docs/decisions/*.md",
            ],
            files: [
                "README.md",
                "AGENTS.md",
                "Package.swift",
            ]
        )

        let warnings = ReadinessRules.findings(for: repo)
            .filter { $0.check == "agents.context" && $0.severity == .warning }

        #expect(warnings.count == 2)
        #expect(warnings.contains { finding in
            finding.title.contains("docs/missing-architecture.md")
                || finding.detail.contains("docs/missing-architecture.md")
        })
        #expect(warnings.contains { finding in
            finding.title.contains("docs/decisions/*.md")
                || finding.detail.contains("docs/decisions/*.md")
        })
    }

    @Test
    func validAgentContextPathsAndGlobsProduceNoReadinessWarning() {
        let repo = snapshot(
            context: [
                "docs/architecture.md",
                "docs/decisions/*.md",
            ],
            files: [
                "README.md",
                "AGENTS.md",
                "Package.swift",
                "docs/architecture.md",
                "docs/decisions/001-storage.md",
                "docs/decisions/002-testing.md",
            ]
        )

        let warnings = ReadinessRules.findings(for: repo)
            .filter { $0.check == "agents.context" && $0.severity == .warning }

        #expect(warnings.isEmpty)
    }

    @Test
    func readinessScanDoesNotRewriteRepositoryConfig() async throws {
        let config = #"""
            {
              "test": {"command": "true"},
              "leafTests": {"target": "AppTests", "folder": "Tests/AppTests"},
              "agents": {"context": ["docs/*.md"]}
            }
            """# + "\n"
        let root = try await makeRepository(files: [
            ".agentos/config.json": config,
            "README.md": "# Product",
            "AGENTS.md": "Build with `true` and test with `true`.",
            "Package.swift": "// swift-tools-version: 6.0\n",
            "docs/architecture.md": "# Architecture",
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        _ = await ReadinessScanner().scan(root)

        #expect(try String(
            contentsOf: root.appending(path: ".agentos/config.json"),
            encoding: .utf8
        ) == config)
        #expect(try await git(["status", "--porcelain"], in: root).isEmpty)
    }

    private func snapshot(context: [String], files: [String]) -> RepositorySnapshot {
        let config = RepoConfig(
            test: .init(command: "swift test"),
            leafTests: .init(target: "AppTests", folder: "Tests/AppTests"),
            agents: .init(context: context)
        )
        var contents = [
            RepoConfig.path: config.json,
            "README.md": "# Product",
            "AGENTS.md": "Build with `swift build` and test with `swift test`.",
            "Package.swift": "// swift-tools-version: 6.0\n",
        ]
        for path in files where contents[path] == nil {
            contents[path] = ""
        }
        return RepositorySnapshot(
            branch: "main",
            commit: "abc1234567",
            files: files + [RepoConfig.path],
            contents: contents
        )
    }

    private func makeWorkspace(
        context: [String]?,
        trackedFiles: [String: String],
        untrackedFiles: [String: String] = [:]
    ) async throws -> WorkspaceFixture {
        let root = try await makeRepository(files: trackedFiles)
        for (path, contents) in untrackedFiles {
            try write(contents, to: root.appending(path: path))
        }
        let storage = FileManager.default.temporaryDirectory
            .appending(path: "agentos-gh-30-2-storage-\(UUID().uuidString)", directoryHint: .isDirectory)
        let config = RepoConfig(
            test: .init(command: "swift test", only: "--filter {suite}"),
            leafTests: .init(target: "AppTests", folder: "Tests/AppTests"),
            agents: .init(context: context)
        )
        let workspace = try RepositoryWorkspace(
            root: root,
            storage: storage,
            config: config,
            landingBranch: "agentos/main",
            defaultBranch: "main"
        )
        return WorkspaceFixture(root: root, storage: storage, workspace: workspace)
    }

    private func makeRepository(files: [String: String]) async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "agentos-gh-30-2-repo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            try write(contents, to: root.appending(path: path))
        }
        try await git(["init", "-q", "-b", "main"], in: root)
        try await git(["add", "."], in: root)
        try await git(
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "initial"],
            in: root
        )
        return root
    }

    private func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct WorkspaceFixture {
    let root: URL
    let storage: URL
    let workspace: RepositoryWorkspace

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storage)
    }
}
