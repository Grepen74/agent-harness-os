import AgentOSCore
import AgentOSAdapters
import AgentOSTestSupport
import Foundation
import Testing

extension GH_150Tests {
    @Test
    func recordedPreflightChecksRulesOnlyInTheExactRecordedFiles() async throws {
        let root = try Files.makeRoot()
        defer { Self.cleanUp(root) }
        let ownFolder = "Kit/Tests/KitTests/GH_150Tests"
        let recorded = "Kit/Tests/KitTests/Feature/GH_150Recorded.swift"
        let safe = "Kit/Tests/KitTests/Helpers/GH_150Safe.swift"
        let missing = "Kit/Tests/KitTests/Helpers/GH_150Gone.swift"
        let bad = "func bad() async throws { try await Task.sleep(for: .seconds(1)) }\n"
        for path in [recorded, ownFolder + "/Unrecorded.swift", "Kit/Tests/KitTests/Feature/Neighbor.swift"] {
            try Files.write(bad, at: path, in: root)
        }
        try Files.write("func validTest() {}\n", at: safe, in: root)
        let files = [recorded, safe, missing]

        let findings = SwiftAcceptanceTestPreflight.testRuleFindings(
            in: root, testFolder: ownFolder, testFiles: files)

        #expect(findings.count == 1)
        #expect(findings.first?.file == recorded)
        #expect(findings.first?.line == 1)
        #expect(findings.first?.breaksTestRules == true)
        #expect(findings.first?.classification == .testAuthorMistake)
        let result = await SwiftAcceptanceTestPreflight().compileTests(
            in: root, testFolder: ownFolder, testFiles: files, expectedAPI: [])
        guard case .diagnostics(let returned, _) = result else {
            Issue.record("Recorded rule violations must be returned even without a Swift package")
            return
        }
        #expect(returned == findings)
    }

    @Test
    func duplicateFilenameDiagnosticsBelongOnlyToExistingRecordedFiles() throws {
        let root = try Files.makeRoot()
        defer { Self.cleanUp(root) }
        let ownFolder = "Kit/Tests/KitTests/GH_150Tests"
        let recorded = "Kit/Tests/KitTests/Feature/Support.swift"
        let otherSupport = "Kit/Tests/KitTests/Older/Support.swift"
        let missing = "Kit/Tests/KitTests/Feature/Gone.swift"
        try Files.write("// swift-tools-version:6.0\n", at: "Kit/Package.swift", in: root)
        for path in [
            recorded, otherSupport,
            "Kit/Tests/KitTests/Feature/Unowned.swift", "Kit/Tests/KitTests/Older/Unowned.swift",
            ownFolder + "/LegacyClash.swift", "Kit/Tests/KitTests/Older/LegacyClash.swift",
            "Kit/Tests/KitTests/Older/Gone.swift",
        ] {
            try Files.write("import Testing\n", at: path, in: root)
        }
        let log = Self.multipleProducers(["Support", "Unowned", "LegacyClash", "Gone"], in: root)

        let classified = SwiftAcceptanceTestPreflight.classify(
            log: log, in: root, testFolder: ownFolder, testFiles: [recorded, missing], expectedAPI: [])

        #expect(classified.diagnostics.count == 1)
        let diagnostic = try #require(classified.testAuthorMistakes.first)
        #expect(diagnostic.file == recorded)
        #expect(diagnostic.message.contains("another file in the same test target is also named Support.swift"))
        #expect(diagnostic.message.contains(otherSupport))
    }

    @Test
    func compilePreflightBuildsThePackageContainingTheRecordedFilesNotTheLegacyFolder() async throws {
        let root = try Files.makeRoot()
        defer { Self.cleanUp(root) }
        let folder = "Recorded/Kit/Tests/KitTests/Feature"
        let file = folder + "/GH_150CompileProbe.swift"
        try Files.write("""
            // swift-tools-version:6.0
            import PackageDescription
            let package = Package(name: "Kit", targets: [
                .target(name: "Kit"),
                .testTarget(name: "KitTests", dependencies: ["Kit"]),
            ])
            """, at: "Recorded/Kit/Package.swift", in: root)
        try Files.write("public struct KitValue {}\n", at: "Recorded/Kit/Sources/Kit/KitValue.swift", in: root)
        try Files.write("import Kit\nfunc acceptance() { _ = KitValue.self }\n", at: file, in: root)
        let control = try await withHangGuard("GH150 compiler fixture control") {
            await SwiftAcceptanceTestPreflight().compileTests(in: root, testFolder: folder, expectedAPI: [])
        }
        guard case .compiled = control else {
            Issue.record("The existing folder API must compile the fixture package")
            return
        }
        let package = root.appending(path: "Recorded/Kit")
        try #require(Self.hasCompiledTestModule(in: package),
                     "Probe the fixture using the existing API, including its actual build product")
        try FileManager.default.removeItem(at: package.appending(path: ".build"))

        let result = try await withHangGuard("GH150 recorded-package compile preflight") {
            await SwiftAcceptanceTestPreflight().compileTests(
                in: root, testFolder: "Legacy/Tests/LegacyTests/GH_150Tests",
                testFiles: [file], expectedAPI: [])
        }

        if case .compiled = result {
            #expect(Self.hasCompiledTestModule(in: package),
                    "The recorded tests' target must actually be compiled")
        } else {
            Issue.record("Preflight must compile the recorded tests' package despite the unrelated legacy folder")
        }
    }

    @Test
    func legacyPreflightUsesItsFolderForRuleFindingsAndDuplicateFilenameDiagnostics() async throws {
        let root = try Files.makeRoot()
        defer { Self.cleanUp(root) }
        let ownFolder = "Kit/Tests/KitTests/GH_150Tests"
        let own = ownFolder + "/Support.swift"
        let nested = ownFolder + "/Nested/GH_150Rules.swift"
        let other = "Kit/Tests/KitTests/Older/Support.swift"
        try Files.write("// swift-tools-version:6.0\n", at: "Kit/Package.swift", in: root)
        for path in [own, nested, other] {
            try Files.write("func bad() async throws { try await Task.sleep(for: .seconds(1)) }\n",
                            at: path, in: root)
        }

        let findings = SwiftAcceptanceTestPreflight.testRuleFindings(in: root, testFolder: ownFolder)
        #expect(Set(findings.map(\.file)) == [own, nested])
        guard case .diagnostics(let returned, _) = await SwiftAcceptanceTestPreflight().compileTests(
            in: root, testFolder: ownFolder, expectedAPI: []) else {
            Issue.record("Legacy folder tests must still be checked before compiling")
            return
        }
        #expect(returned == findings)
        let classified = SwiftAcceptanceTestPreflight.classify(
            log: Self.multipleProducers(["Support"], in: root), in: root,
            testFolder: ownFolder, expectedAPI: [])
        #expect(classified.diagnostics.count == 1)
        #expect(classified.testAuthorMistakes.first?.file == own)
        #expect(classified.testAuthorMistakes.first?.message.contains(other) == true)
    }

    private static func multipleProducers(_ names: [String], in root: URL) -> String {
        names.map {
            "error: couldn't build \(root.path)/Kit/.build/debug/KitTests.build/\($0).swift.o because of multiple producers"
        }.joined(separator: "\n")
    }

    private static func hasCompiledTestModule(in package: URL) -> Bool {
        guard let files = FileManager.default.enumerator(
            at: package.appending(path: ".build"), includingPropertiesForKeys: nil
        ) else { return false }
        return files.contains { ($0 as? URL)?.lastPathComponent == "KitTests.swiftmodule" }
    }

    private static func cleanUp(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Cannot remove GH150 preflight fixture: \(error)") }
    }
}
