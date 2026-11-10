// API contract: RepositoryWorkspace.catchUpActiveLeaves rebases every supplied in-progress leaf and reports leaves moved into rework.

import Foundation
import Testing
@testable import AgentOSAdapters
import AgentOSCore

@Suite
struct GH_4_4Tests {
    private static let config = RepoConfig(
        test: .init(command: "true"),
        leafTests: .init(target: "AgentOSAdaptersTests", folder: "Tests/AgentOSAdaptersTests")
    )

    @Test
    func everyInProgressLeafIsRebasedOntoTheNewLandingTip() async throws {
        let fixture = try await makeFixture()
        let first = try await fixture.makeLeaf("first", implementation: ["first.txt": "first change\n"])
        let second = try await fixture.makeLeaf("second", implementation: ["second.txt": "second change\n"])
        let newTip = try await fixture.catchUpLandingBranch(changes: ["base.txt": "new main\n"])

        let result = try await fixture.workspace.catchUpActiveLeaves(["first", "second"])

        #expect(Set(result.rebased) == ["first", "second"])
        #expect(result.rework.isEmpty)
        #expect(try await Self.isAncestor(newTip, of: fixture.workspace.branch(for: "first"), in: fixture.repo))
        #expect(try await Self.isAncestor(newTip, of: fixture.workspace.branch(for: "second"), in: fixture.repo))
        #expect(try await fixture.workspace.head(of: first) != newTip)
        #expect(try await fixture.workspace.head(of: second) != newTip)
    }

    @Test
    func cleanLeafKeepsItsChangesAfterRebase() async throws {
        let fixture = try await makeFixture()
        let leaf = try await fixture.makeLeaf("clean", implementation: [
            "feature.txt": "work in progress\n",
            "notes.txt": "keep this too\n",
        ])
        let before = try Self.contents(["feature.txt", "notes.txt"], in: leaf)
        _ = try await fixture.catchUpLandingBranch(changes: ["base.txt": "new main\n"])

        let result = try await fixture.workspace.catchUpActiveLeaves(["clean"])

        #expect(result.rebased == ["clean"])
        #expect(result.rework.isEmpty)
        #expect(try Self.contents(["feature.txt", "notes.txt"], in: leaf) == before)
        #expect(try String(contentsOf: leaf.appending(path: "base.txt"), encoding: .utf8) == "new main\n")
    }

    @Test
    func conflictingLeafEntersReworkAndReportsConflictingFiles() async throws {
        let fixture = try await makeFixture()
        let leaf = try await fixture.makeLeaf("conflict", implementation: [
            "shared.txt": "leaf version\n",
            "implementation.txt": "discard during rework\n",
        ])
        _ = try await fixture.catchUpLandingBranch(changes: ["shared.txt": "main version\n"])

        let result = try await fixture.workspace.catchUpActiveLeaves(["conflict"])

        #expect(result.rebased.isEmpty)
        #expect(result.rework["conflict"] == ["shared.txt"])
        #expect(FileManager.default.fileExists(
            atPath: leaf.appending(path: "Tests/AgentOSAdaptersTests/GH_conflictTests/acceptance.txt").path
        ))
        #expect(!FileManager.default.fileExists(atPath: leaf.appending(path: "implementation.txt").path))
        #expect(try String(contentsOf: leaf.appending(path: "shared.txt"), encoding: .utf8) == "main version\n")
    }

    @Test
    func oneConflictDoesNotRollbackLandingTipOrBlockCleanLeaves() async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.makeLeaf("conflict", implementation: ["shared.txt": "leaf version\n"])
        let clean = try await fixture.makeLeaf("clean", implementation: ["clean.txt": "clean change\n"])
        let newTip = try await fixture.catchUpLandingBranch(changes: ["shared.txt": "main version\n"])

        let result = try await fixture.workspace.catchUpActiveLeaves(["conflict", "clean"])

        #expect(result.rework["conflict"] == ["shared.txt"])
        #expect(result.rebased == ["clean"])
        #expect(try await Self.revision("agentos/main", in: fixture.repo) == newTip)
        #expect(try await Self.isAncestor(newTip, of: fixture.workspace.branch(for: "clean"), in: fixture.repo))
        #expect(try String(contentsOf: clean.appending(path: "clean.txt"), encoding: .utf8) == "clean change\n")
    }

    private struct Fixture {
        let repo: URL
        let workspace: RepositoryWorkspace

        func makeLeaf(_ id: NodeID, implementation: [String: String]) async throws -> URL {
            let directory = try await workspace.createWorktree(for: id)
            let acceptance = directory.appending(path: "Tests/AgentOSAdaptersTests/GH_\(id)Tests/acceptance.txt")
            try FileManager.default.createDirectory(
                at: acceptance.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "acceptance contract\n".write(to: acceptance, atomically: true, encoding: .utf8)
            try #require(try await workspace.commitAll(
                in: directory,
                message: "\(id) acceptance tests",
                author: "test-author"
            ) != nil)

            for (path, text) in implementation {
                try text.write(to: directory.appending(path: path), atomically: true, encoding: .utf8)
            }
            try #require(try await workspace.commitAll(
                in: directory,
                message: "\(id) implementation",
                author: "implementer"
            ) != nil)
            return directory
        }

        func catchUpLandingBranch(changes: [String: String]) async throws -> String {
            for (path, text) in changes {
                try text.write(to: repo.appending(path: path), atomically: true, encoding: .utf8)
            }
            try await GH_4_4Tests.git(["add", "."], in: repo)
            try await GH_4_4Tests.git([
                "-c", "user.name=Main",
                "-c", "user.email=main@example.com",
                "commit", "-q", "-m", "main moved",
            ], in: repo)
            let tip = try await GH_4_4Tests.revision("main", in: repo)
            try await GH_4_4Tests.git(["branch", "-f", "agentos/main", tip], in: repo)
            return tip
        }
    }

    private func makeFixture() async throws -> Fixture {
        let repo = FileManager.default.temporaryDirectory
            .appending(path: "agentos-GH-4-4-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "original\n".write(to: repo.appending(path: "base.txt"), atomically: true, encoding: .utf8)
        try "original\n".write(to: repo.appending(path: "shared.txt"), atomically: true, encoding: .utf8)
        try await Self.git(["init", "-q", "-b", "main"], in: repo)
        try await Self.git(["add", "."], in: repo)
        try await Self.git([
            "-c", "user.name=Test",
            "-c", "user.email=test@example.com",
            "commit", "-q", "-m", "initial",
        ], in: repo)

        let storage = FileManager.default.temporaryDirectory
            .appending(path: "agentos-GH-4-4-storage-\(UUID().uuidString)")
        let workspace = try RepositoryWorkspace(
            root: repo,
            storage: storage,
            config: Self.config,
            landingBranch: "agentos/main",
            defaultBranch: "main"
        )
        try await workspace.prepare()
        return Fixture(repo: repo, workspace: workspace)
    }

    private static func contents(_ paths: [String], in directory: URL) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: paths.map { path in
            (path, try String(contentsOf: directory.appending(path: path), encoding: .utf8))
        })
    }

    private static func isAncestor(_ ancestor: String, of descendant: String, in repo: URL) async throws -> Bool {
        let result = try await ProcessRunner.run(
            "/usr/bin/env",
            ["git", "merge-base", "--is-ancestor", ancestor, descendant],
            in: repo
        )
        return result.status == 0
    }

    private static func revision(_ name: String, in repo: URL) async throws -> String {
        try await git(["rev-parse", name], in: repo)
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
        try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
