import AgentOSCore
import Foundation

/// A first `.agentos/config.json` for a repo that has none, guessed from its build systems.
/// Shown for a human to check and commit. The config steers the harness, so the harness never commits it itself.
enum RepoConfigDraft {
    static func make(_ repo: RepositorySnapshot, _ build: ReadinessRules.BuildSystems) -> RepoConfig? {
        var checks: [RepoConfig.NamedCheck] = []
        var test: RepoConfig.Test?
        var leafTests: RepoConfig.LeafTests?

        for package in build.packages where package.hasTests {
            let command = cd(package.folder, "swift test")
            if test == nil {
                test = RepoConfig.Test(command: command, only: "--filter {suite}")
                leafTests = testFolders(of: package.folder, in: repo).first
            } else {
                checks.append(RepoConfig.NamedCheck(name: "test \(package.folder)", command: command))
            }
        }

        var prepare: [String] = []
        for project in build.projects {
            if let spec = project.spec {
                prepare.append(cd(project.folder, spec.hasSuffix(".yml") ? "xcodegen generate" : "tuist generate"))
            }
            let path = project.pbxproj?.folder ?? "\(projectName(project, repo)).xcodeproj".inFolder(project.folder)
            let scheme = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let destination = destination(project, repo)
            let base = "xcodebuild -project \(path) -scheme \(scheme) -destination '\(destination)' "
                + "-derivedDataPath .build/agentos-xcode -quiet"
            if project.hasTests && test == nil {
                test = RepoConfig.Test(command: "\(base) test", only: "-only-testing:{suite}")
            } else {
                checks.append(RepoConfig.NamedCheck(name: "\(project.hasTests ? "test" : "build") \(scheme)",
                                                    command: "\(base) \(project.hasTests ? "test" : "build")"))
            }
        }

        guard let test else { return nil }
        return RepoConfig(
            build: prepare.isEmpty ? nil : RepoConfig.Build(prepare: prepare.joined(separator: " && "), command: nil),
            test: test, checks: checks.isEmpty ? nil : checks, leafTests: leafTests,
            components: components(build, repo), landing: RepoConfig.Landing(branch: HarnessSettings().landingBranch))
    }

    private static func cd(_ folder: String, _ command: String) -> String {
        folder == "." ? command : "cd \(folder) && \(command)"
    }

    /// `Tests/<Target>/` folders of a package.
    private static func testFolders(of folder: String, in repo: RepositorySnapshot) -> [RepoConfig.LeafTests] {
        let prefix = "Tests/".inFolder(folder)
        let targets = Set(repo.files.filter { $0.hasPrefix(prefix) }.compactMap {
            $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        }.filter { !$0.contains(".") })
        return targets.sorted().map { RepoConfig.LeafTests(target: $0, folder: prefix + $0) }
    }

    /// The packages' source modules: a first guess at the components leaves are assigned to.
    private static func components(_ build: ReadinessRules.BuildSystems, _ repo: RepositorySnapshot) -> [String]? {
        let modules = build.packages.flatMap { package -> [String] in
            let prefix = "Sources/".inFolder(package.folder)
            return Set(repo.files.filter { $0.hasPrefix(prefix) }.compactMap { path -> String? in
                let parts = path.dropFirst(prefix.count).split(separator: "/")
                return parts.count > 1 ? prefix + parts[0] : nil
            }).sorted()
        }
        return modules.isEmpty ? nil : modules
    }

    private static func projectName(_ project: (name: String, folder: String, pbxproj: String?, spec: String?, hasTests: Bool),
                                     _ repo: RepositorySnapshot) -> String {
        let spec = project.spec.flatMap { repo.contents[$0] } ?? ""
        let name = spec.split(separator: "\n").first { $0.hasPrefix("name:") }
            .map { $0.dropFirst("name:".count).trimmingCharacters(in: .whitespaces.union(["\"", "'"])) }
        return name ?? (project.folder == "." ? "App" : (project.folder as NSString).lastPathComponent)
    }

    /// macOS unless the project targets iOS; then an installed iPhone simulator, if known.
    private static func destination(_ project: (name: String, folder: String, pbxproj: String?, spec: String?, hasTests: Bool),
                                    _ repo: RepositorySnapshot) -> String {
        let text = [project.pbxproj, project.spec].compactMap { $0.flatMap { repo.contents[$0] } }.joined()
        guard text.contains("iphoneos") || text.contains("platform: iOS") || text.contains(".iOS") else { return "platform=macOS" }
        let iPhone = repo.simulators?.sorted { $0.key > $1.key }
            .lazy.compactMap { runtime, names in names.sorted().last { $0.hasPrefix("iPhone") }.map { ($0, runtime) } }.first
        guard let (name, runtime) = iPhone, let os = runtime.split(separator: " ").last else {
            return "platform=iOS Simulator,name=iPhone 16"
        }
        return "platform=iOS Simulator,name=\(name),OS=\(os)"
    }
}
