import AgentOSCore
import Foundation

/// The readiness checks for a Swift / Xcode repo (design: docs/real-repo-mode.md, "Readiness scan").
/// Pure: everything they need is in the snapshot, so they never touch the repo.
/// Deliberately generous with findings: a gap found now is cheaper than one an agent finds halfway through a leaf.
enum ReadinessRules {
    static func findings(for repo: RepositorySnapshot) -> [Finding] {
        var findings = [Finding(
            check: "repo.branch", severity: .info,
            title: "Works from \(repo.branch) at \(repo.commit.prefix(8))",
            detail: "\(repo.files.count) tracked files. The scan reads this branch only, never your working copy."
        )]
        let build = BuildSystems(repo)
        findings += build.findings
        findings += config(repo, build)
        findings += instructions(repo)
        findings += docs(repo)
        findings += hotspots(repo, build)
        findings += tests(repo, build)
        findings += codeowners(repo)
        findings += checkout(repo)
        return findings
    }

    // MARK: Build and test

    /// The Swift packages and Xcode projects on the branch.
    struct BuildSystems {
        var packages: [(folder: String, hasTests: Bool)] = []
        /// Committed projects, plus projects that are only generated from a spec.
        var projects: [(name: String, folder: String, pbxproj: String?, spec: String?, hasTests: Bool)] = []
        var findings: [Finding] = []

        init(_ repo: RepositorySnapshot) {
            for path in repo.paths(named: "Package.swift") {
                let hasTests = repo.contents[path]?.contains(".testTarget(") == true
                packages.append((path.folder, hasTests))
                findings.append(Finding(check: "build.system", severity: .info,
                                        title: "Swift package in \(path.folder)",
                                        detail: hasTests ? "Has test targets: `swift test`." : "No test targets."))
            }

            var specs = Set(repo.paths(named: "project.yml") + repo.paths(named: "Project.swift"))
            for pbxproj in repo.contents.keys.filter({ $0.hasSuffix(".xcodeproj/project.pbxproj") }).sorted() {
                let project = pbxproj.folder
                let folder = project.folder
                let spec = ["project.yml", "Project.swift"].map { $0.inFolder(folder) }.first { specs.contains($0) }
                if let spec { specs.remove(spec) }
                let hasTests = Self.hasTestTarget(repo.contents[pbxproj]) || Self.hasTestTarget(spec.flatMap { repo.contents[$0] })
                projects.append(((project as NSString).lastPathComponent, folder, pbxproj, spec, hasTests))
                findings.append(Finding(check: "build.system", severity: .info,
                                        title: "Xcode project \(project)",
                                        detail: spec.map { "Generated from \($0) (\($0.hasSuffix(".yml") ? "XcodeGen" : "Tuist"))." }
                                            ?? "Maintained in Xcode."))
            }
            for spec in specs.sorted() {
                let hasTests = Self.hasTestTarget(repo.contents[spec])
                projects.append((spec, spec.folder, nil, spec, hasTests))
                findings.append(Finding(check: "build.system", severity: .info,
                                        title: "Generated Xcode project from \(spec)",
                                        detail: "The project file isn't committed: it's generated before each build."))
            }

            if packages.isEmpty && projects.isEmpty {
                findings.append(Finding(
                    check: "build.system", severity: .blocker, title: "No way to build found",
                    detail: "No Package.swift, Xcode project, XcodeGen or Tuist spec on the branch.",
                    suggestion: "Name the build and test commands in .agentos/config."))
            }
        }

        static func hasTestTarget(_ text: String?) -> Bool {
            guard let text else { return false }
            return ["com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle.ui-testing",
                    "bundle.unit-test", "bundle.ui-testing", ".unitTests", ".uiTests"].contains { text.contains($0) }
        }

        /// How tests could be run today, in words.
        var testEntryPoints: [String] {
            packages.filter(\.hasTests).map { "`swift test` in \($0.folder)" }
                + projects.filter(\.hasTests).map { "`xcodebuild test` for \($0.name)" }
        }
    }

    static func config(_ repo: RepositorySnapshot, _ build: BuildSystems) -> [Finding] {
        guard repo.contents[".agentos/config"] == nil else {
            return [Finding(check: "config", severity: .info, title: "Repo config found: .agentos/config",
                            detail: "Not validated yet: checking it against the harness limits comes with config support.")]
        }
        let entryPoints = build.testEntryPoints
        let found = switch entryPoints.count {
        case 0: "No test entry point was found either."
        case 1: "Found one test entry point: \(entryPoints[0])."
        default: "Found \(entryPoints.count) test entry points, so the harness can't pick one: "
            + entryPoints.joined(separator: ", ") + "."
        }
        return [
            Finding(check: "config", severity: .blocker, title: "No repo config",
                    detail: "The harness needs to know how to build and test before agents start. " + found,
                    suggestion: "Add .agentos/config on \(repo.branch) with the build and test commands."),
            Finding(check: "baseline", severity: .info, title: "Baseline not checked",
                    detail: "Tests must pass on \(repo.branch) before any work starts, or no leaf could ever land. "
                        + "They're run once the test command is configured."),
        ]
    }

    // MARK: Files that steer agents (doc 01)

    static func instructions(_ repo: RepositorySnapshot) -> [Finding] {
        let candidates = [repo.file(named: "AGENTS"), repo.contents[".github/copilot-instructions.md"] == nil ? nil : ".github/copilot-instructions.md"]
            .compactMap { $0 }
        guard !candidates.isEmpty else {
            return [Finding(check: "agents.instructions", severity: .warning, title: "No instructions for agents",
                            detail: "No AGENTS.md or .github/copilot-instructions.md. Agents will guess conventions, "
                                + "how to build and how to test.",
                            suggestion: "Add AGENTS.md with the build and test commands and the conventions agents must follow.")]
        }
        let text = candidates.compactMap { repo.contents[$0]?.lowercased() }.joined(separator: "\n")
        let missing = ["build", "test"].filter { !text.contains($0) }
        guard missing.isEmpty else {
            return [Finding(check: "agents.instructions", severity: .warning,
                            title: "Agent instructions don't say how to \(missing.joined(separator: " or "))",
                            detail: "Read: \(candidates.joined(separator: ", ")).",
                            suggestion: "Add the exact commands to \(candidates[0]).")]
        }
        return [Finding(check: "agents.instructions", severity: .info,
                        title: "Agent instructions found: \(candidates.joined(separator: ", "))")]
    }

    static func docs(_ repo: RepositorySnapshot) -> [Finding] {
        var findings: [Finding] = []
        if repo.file(named: "README") == nil {
            findings.append(Finding(check: "docs.readme", severity: .warning, title: "No README",
                                    detail: "Nothing explains what this repo is for, to humans or agents.",
                                    suggestion: "Add a README.md."))
        }
        if let contributing = repo.file(named: "CONTRIBUTING", in: ["", ".github", "docs"]) {
            if repo.contents[contributing]?.lowercased().contains("definition of done") != true {
                findings.append(Finding(check: "docs.contributing", severity: .warning,
                                        title: "\(contributing) has no Definition of Done",
                                        detail: "Without one, \"finished\" means whatever the agent thinks it means.",
                                        suggestion: "Add a \"Definition of Done\" section."))
            }
        } else {
            findings.append(Finding(check: "docs.contributing", severity: .warning, title: "No CONTRIBUTING",
                                    detail: "No shared rules for changes, and no Definition of Done.",
                                    suggestion: "Add CONTRIBUTING.md with the rules for changes and a Definition of Done."))
        }
        return findings
    }

    // MARK: Xcode

    /// A project file that every new source file changes is the biggest merge hotspot in an Xcode repo (doc 08 §8).
    static func hotspots(_ repo: RepositorySnapshot, _ build: BuildSystems) -> [Finding] {
        build.projects.compactMap { project in
            guard let pbxproj = project.pbxproj else { return nil }
            if let spec = project.spec {
                return Finding(
                    check: "xcode.hotspot", severity: .warning, title: "Generated project file is committed: \(pbxproj)",
                    detail: "It's generated from \(spec), but committed too, so adding a file changes it and "
                        + "parallel leaves conflict on it.",
                    suggestion: "Stop committing it, or name the generate command as the prepare step in .agentos/config "
                        + "so the harness regenerates it instead of agents editing it.")
            }
            if repo.contents[pbxproj]?.contains("PBXFileSystemSynchronizedRootGroup") == true {
                return Finding(check: "xcode.hotspot", severity: .info, title: "\(project.name) uses synchronized folders",
                               detail: "New files don't change the project file.")
            }
            return Finding(
                check: "xcode.hotspot", severity: .warning, title: "Project file is a merge hotspot: \(pbxproj)",
                detail: "Every new file changes it, so leaves built in parallel will conflict on it.",
                suggestion: "Convert groups to folders (Xcode 16 or later), or generate the project with XcodeGen or Tuist.")
        }
    }

    // MARK: Tests

    static func tests(_ repo: RepositorySnapshot, _ build: BuildSystems) -> [Finding] {
        var findings: [Finding] = []
        for package in build.packages where !package.hasTests {
            findings.append(Finding(check: "tests.target", severity: .warning,
                                    title: "Swift package in \(package.folder) has no test target",
                                    detail: "Leaves need an existing test target for their acceptance tests.",
                                    suggestion: "Add a test target."))
        }
        for project in build.projects where !project.hasTests {
            findings.append(Finding(check: "tests.target", severity: .warning, title: "\(project.name) has no test target",
                                    detail: "Leaves need an existing test target for their acceptance tests.",
                                    suggestion: "Add a unit test target to \(project.spec ?? project.name)."))
        }

        let frameworks = [("Swift Testing", repo.swiftTestingFiles), ("XCTest", repo.xctestFiles)].filter { $0.1 > 0 }
        if frameworks.isEmpty {
            if build.packages.contains(where: \.hasTests) || build.projects.contains(where: \.hasTests) {
                findings.append(Finding(check: "tests.framework", severity: .warning, title: "Test framework unknown",
                                        detail: "There are test targets, but no file imports Testing or XCTest.",
                                        suggestion: "Say in AGENTS.md which framework new tests use."))
            }
        } else {
            findings.append(Finding(check: "tests.framework", severity: .info,
                                    title: "Tests use " + frameworks.map(\.0).joined(separator: " and "),
                                    detail: frameworks.map { "\($0.0): \($0.1) files" }.joined(separator: ", ") + "."))
        }
        return findings
    }

    // MARK: Approvals and your checkout

    static func codeowners(_ repo: RepositorySnapshot) -> [Finding] {
        let steering = ["AGENTS.md", "CONTRIBUTING", ".agentos"]
        guard let path = repo.file(named: "CODEOWNERS", in: ["", ".github", "docs"]), let text = repo.contents[path] else {
            return [Finding(check: "codeowners", severity: .info, title: "No CODEOWNERS",
                            detail: "Changes to the files that steer agents (\(steering.joined(separator: ", "))) "
                                + "need no particular reviewer.",
                            suggestion: "Add CODEOWNERS entries for them.")]
        }
        let patterns = text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return trimmed.split(separator: " ").first.map(String.init)
        }
        if patterns.contains(where: { $0 == "*" || $0 == "/*" || $0 == "/" }) {
            return [Finding(check: "codeowners", severity: .info, title: "\(path) covers every file")]
        }
        let uncovered = steering.filter { name in !patterns.contains { $0.contains(name) } }
        guard !uncovered.isEmpty else {
            return [Finding(check: "codeowners", severity: .info, title: "\(path) covers the files that steer agents")]
        }
        return [Finding(check: "codeowners", severity: .info, title: "\(path) doesn't cover \(uncovered.joined(separator: ", "))",
                        suggestion: "Add entries for them, so changes to agent instructions need an owner's approval.")]
    }

    static func checkout(_ repo: RepositorySnapshot) -> [Finding] {
        var findings: [Finding] = []
        if let current = repo.checkoutBranch, current != repo.branch {
            findings.append(Finding(check: "checkout", severity: .info, title: "Your checkout is on \(current)",
                                    detail: "The harness works from \(repo.branch), not from your current branch."))
        }
        if repo.uncommittedChanges > 0 {
            findings.append(Finding(check: "checkout", severity: .info,
                                    title: "\(repo.uncommittedChanges) uncommitted change\(repo.uncommittedChanges == 1 ? "" : "s") in your checkout",
                                    detail: "The harness works from \(repo.branch) and won't include them."))
        }
        return findings
    }
}
