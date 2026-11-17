import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

extension GH_88Tests {
    final class RepositoryFixture: Sendable {
        let directory: URL
        let repo: URL
        let origin: URL
        let storage: URL
        let workspace: RepositoryWorkspace
        let initialMain: String
        let originalRemoteRefs: String

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "GH-88-repository-\(UUID())")
            let cleanupDirectory = directory
            var initialized = false
            defer {
                if !initialized {
                    do { try FileManager.default.removeItem(at: cleanupDirectory) }
                    catch { Issue.record("Could not remove the incomplete GH-88 repository fixture: \(error)") }
                }
            }
            repo = directory.appending(path: "repo")
            origin = directory.appending(path: "origin.git")
            storage = directory.appending(path: "storage")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try "base\n".write(to: repo.appending(path: "base.txt"), atomically: true, encoding: .utf8)
            try await Self.git(["init", "-q", "-b", "main"], in: repo)
            try await Self.git(["config", "user.name", "GH-88 fixture"], in: repo)
            try await Self.git(["config", "user.email", "gh88@example.invalid"], in: repo)
            try await Self.git(["add", "."], in: repo)
            try await Self.git(["commit", "-q", "-m", "initial"], in: repo)
            initialMain = try await Self.git(["rev-parse", "main"], in: repo)
            try await Self.git(["clone", "-q", "--bare", "--no-hardlinks", repo.path, origin.path], in: directory)
            try await Self.git(["remote", "add", "origin", origin.path], in: repo)
            originalRemoteRefs = try await Self.git(
                ["--git-dir", origin.path, "for-each-ref", "--format=%(refname) %(objectname)"], in: directory
            )
            let hook = repo.appending(path: ".git/hooks/pre-push")
            try "#!/bin/sh\nprintf 'attempted\\n' >> \"$(git rev-parse --git-common-dir)/GH-88-push-attempts\"\nexit 1\n"
                .write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            try await Self.git(["switch", "-q", "-c", "personal-checkout"], in: repo)
            workspace = try Self.makeWorkspace(root: repo, storage: storage)
            #expect(try await Self.git(["show", "\(initialMain):base.txt"], in: repo) == "base",
                    "Verify the repository helper against a commit made with the existing git API")
            initialized = true
        }

        private static func makeWorkspace(root: URL, storage: URL) throws -> RepositoryWorkspace {
            try RepositoryWorkspace(
                root: root, storage: storage,
                config: RepoConfig(test: .init(command: "true"),
                                   leafTests: .init(target: "AppTests", folder: "Tests/AppTests")),
                landingBranch: "agentos/main", defaultBranch: "main"
            )
        }

        func freshWorkspace() throws -> RepositoryWorkspace {
            try Self.makeWorkspace(root: repo, storage: storage)
        }

        func revision(_ ref: String) async throws -> String {
            try await Self.git(["rev-parse", "--verify", ref], in: repo)
        }

        func branches() async throws -> Set<String> {
            Set(try await Self.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repo)
                .split(separator: "\n").map(String.init))
        }

        func contains(_ ancestor: String, on branch: String) async throws -> Bool {
            let result = try await ProcessRunner.run(
                "/usr/bin/env", ["git", "merge-base", "--is-ancestor", ancestor, branch], in: repo
            )
            try #require(result.status == 0 || result.status == 1, "\(result.output)")
            return result.status == 0
        }

        @discardableResult
        func commit(on branch: String, file: String, contents: String) async throws -> String {
            let checkout = directory.appending(path: "commit-\(UUID())")
            let before = try await revision(branch)
            try await Self.git(["worktree", "add", "-q", "--detach", checkout.path, before], in: repo)
            try contents.write(to: checkout.appending(path: file), atomically: true, encoding: .utf8)
            try await Self.git(["add", file], in: checkout)
            try await Self.git(["commit", "-q", "-m", file], in: checkout)
            let commit = try await Self.git(["rev-parse", "HEAD"], in: checkout)
            try await Self.git(["update-ref", "refs/heads/\(branch)", commit, before], in: repo)
            try await Self.git(["worktree", "remove", checkout.path], in: repo)
            return commit
        }

        @discardableResult
        func leafCommit(_ spec: NodeSpec, file: String) async throws -> String {
            let checkout = try await workspace.createWorktree(for: spec.id)
            let tests = checkout.appending(path: workspace.testFolder(for: spec))
            try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
            try "acceptance fixture\n".write(to: tests.appending(path: "Acceptance.txt"), atomically: true, encoding: .utf8)
            _ = try #require(try await workspace.commitAll(in: checkout, message: "\(spec.id) tests", author: "test-author"))
            try "\(spec.id)\n".write(to: checkout.appending(path: file), atomically: true, encoding: .utf8)
            return try #require(try await workspace.commitAll(in: checkout, message: spec.id, author: "implementer"))
        }

        func assertNoPush() async throws {
            #expect(!FileManager.default.fileExists(atPath: repo.appending(path: ".git/GH-88-push-attempts").path))
            #expect(try await Self.git(
                ["--git-dir", origin.path, "for-each-ref", "--format=%(refname) %(objectname)"], in: directory
            )
                    == originalRemoteRefs)
        }

        func assertPersonalCheckout(head: String, status: String) async throws {
            #expect(try await Self.git(["branch", "--show-current"], in: repo) == "personal-checkout")
            #expect(try await revision("HEAD") == head)
            #expect(try await Self.git(["status", "--porcelain"], in: repo) == status)
        }

        func cleanUp() {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Could not remove the GH-88 repository fixture: \(error)") }
        }

        @discardableResult
        static func git(_ arguments: [String], in directory: URL) async throws -> String {
            let result = try await ProcessRunner.run("/usr/bin/env", ["git"] + arguments, in: directory)
            try #require(result.status == 0, "git \(arguments.joined(separator: " ")): \(result.output)")
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
