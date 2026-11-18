// Expected API: ChildProposal.predictedPaths: [String]? and NodeSpec.predictedPaths: [String].
// The decomposer's optional JSON field flows through planning and ledger events into previews
// and NodeDetail's Paths row. Existing parsing, reconciler, ledger and rendering APIs are reused.
import AgentOSTestSupport
import Foundation
import SwiftUI
import Testing
import Vision
@testable import AgentOSAdapters
@testable import AgentOSCore
@testable import AgentOSUI

@Suite(.timeLimit(.minutes(5))) struct GH_75Tests {
    @Test(arguments: [false, true])
    func decomposerAcceptsPredictedFilesAndDirectoriesAlongsideChildrenWithoutPaths(bareArray: Bool) throws {
        let children = """
        [
          {"title":"Store greeting","acceptanceCriteria":["A greeting is stored"],
           "touches":["Storage"],"predictedPaths":["Sources/Store.swift","Resources/Greetings"]},
          {"title":"Show greeting","acceptanceCriteria":["A greeting is visible"],"touches":["Display"]}
        ]
        """
        let output = bareArray ? children : #"{"children":\#(children),"questions":[],"assumptions":[]}"#
        let result = try #require(CopilotDecomposer.parse(output))
        try #require(result.children.count == 2)
        #expect(result.children[0].predictedPaths == ["Sources/Store.swift", "Resources/Greetings"])
        #expect((result.children[1].predictedPaths ?? []).isEmpty)

        let restored = try JSONDecoder().decode(
            [ChildProposal].self, from: JSONEncoder().encode(result.children))
        #expect(restored[0].predictedPaths == result.children[0].predictedPaths)
        #expect((restored[1].predictedPaths ?? []).isEmpty)
    }

    @Test
    func copilotPromptRequestsRepositoryRelativeFilesOrDirectoryPrefixesForEachLeaf() {
        let prompt = CopilotDecomposer.prompt(for: BreakdownRequest(spec: Self.rootSpec))
        #expect(prompt.contains("\"predictedPaths\""), "The response schema must request predictions.")
        #expect(Self.matches(prompt, #"repo(sitory)?[- ]relative"#))
        #expect(Self.matches(prompt, #"director(y|ies)"#))
        #expect(Self.matches(prompt, #"file(s)?"#))
        #expect(Self.matches(prompt, #"(?s)(each|per).{0,180}(leaf|child).{0,180}(path|predict)|(path|predict).{0,180}(each|per).{0,180}(leaf|child)"#),
                "Ask for paths per leaf, not one prediction for the whole ticket.")
    }

    @Test
    func planningNormalizesPathsWithoutChangingTheirRepositoryRelativeSpelling() throws {
        let proposal = Self.proposal("Store greeting", touches: ["Storage"], paths: [
            "./Sources/Store.swift", "Sources/Store.swift", "Resources/Greetings/", "./Resources/Greetings",
            ".github/workflows/check.yml", "Sources/V2.0/Store.swift",
            "/outside/Store.swift", "//server/Store.swift", "../Store.swift", "Sources/../Store.swift",
            "./../Store.swift", "Sources/..",
        ])
        let planned = Planner.childSpecs(parent: Self.rootSpec, proposals: [proposal])
        let leaf = try #require(planned.first)
        let expected = ["Sources/Store.swift", "Resources/Greetings",
                        ".github/workflows/check.yml", "Sources/V2.0/Store.swift"]
        #expect(Set(leaf.predictedPaths) == Set(expected))
        #expect(leaf.predictedPaths.count == expected.count, "Duplicates are removed after normalization.")
    }

    @Test
    func everyCreatedLeafKeepsItsOwnPredictionsAndTouchesWhenTheLedgerIsReloaded() async throws {
        let fixture = try Fixture(children: [
            Self.proposal("Store greeting", touches: ["Storage"],
                          paths: ["./Sources/Store.swift", "Resources/Greetings/"]),
            Self.proposal("Show greeting", touches: ["Display"], paths: ["Sources/Display"]),
            Self.proposal("Speak greeting", touches: ["Speech"], paths: nil),
        ])
        try await fixture.breakDown()
        let before = await fixture.ledger.workingState()
        let reloaded = try await Self.reload(fixture.ledger)

        for state in [before, reloaded] {
            let root = try #require(state.nodes[Self.rootSpec.id])
            try #require(root.children.count == 3)
            for (title, touches, paths) in [
                ("Store greeting", ["Storage"], ["Sources/Store.swift", "Resources/Greetings"]),
                ("Show greeting", ["Display"], ["Sources/Display"]),
                ("Speak greeting", ["Speech"], []),
            ] {
                let leaf = try #require(root.children.compactMap { state.nodes[$0] }.first { $0.spec.title == title })
                #expect(leaf.spec.kind == .leaf)
                #expect(leaf.spec.touches == touches)
                #expect(Set(leaf.spec.predictedPaths) == Set(paths))
            }
        }
    }

    @Test(arguments: [false, true])
    func aTicketBuiltAsOneLeafStoresItsPredictionsIncludingWhenAcceptingAPreview(usePreview: Bool) async throws {
        let fixture = try Fixture(children: [
            Self.proposal(Self.rootSpec.title, touches: ["Storage"],
                          paths: ["./Sources/Store.swift", "Resources/Greetings/"]),
        ])
        if usePreview { _ = try await fixture.preview() }
        try await fixture.breakDown()
        let reloaded = try await Self.reload(fixture.ledger)
        let leaf = try #require(reloaded.nodes[Self.rootSpec.id])
        #expect(leaf.spec.kind == .leaf)
        #expect(leaf.children.isEmpty)
        #expect(leaf.spec.touches == ["Storage"])
        #expect(Set(leaf.spec.predictedPaths) == ["Sources/Store.swift", "Resources/Greetings"])
        if usePreview { #expect(await fixture.decomposer.calls == 1) }
    }

    @Test(arguments: [false, true])
    func replanningKeepsTheLeafAndItsTestsButReplacesItsPredictionsWithTheNewBreakdown(omitNewPaths: Bool) async throws {
        let original = Self.proposal("Store greeting", touches: ["Storage"], paths: ["Sources/OldStore.swift"])
        let other = Self.proposal("Show greeting", touches: ["Display"], paths: ["Sources/Display"])
        let fixture = try Fixture(children: [original, other])
        try await fixture.breakDown()
        let first = await fixture.ledger.workingState()
        let oldLeaf = try #require(first.nodes.values.first { $0.spec.title == original.title })
        try await fixture.ledger.append([
            LedgerEvent(node: oldLeaf.id, by: .agent(run: "tests", role: .testAuthor),
                        kind: .testsFixed(digest: "authored-tests")),
            LedgerEvent(node: oldLeaf.id, by: .reconciler, kind: .phaseChanged(to: .ready)),
            LedgerEvent(node: oldLeaf.id, by: .human("Reviewer"), kind: .gateOpened(.build)),
        ])

        let state = await fixture.ledger.workingState()
        _ = try await fixture.reconciler.replan(state.nodes[Self.rootSpec.id], ticket: Self.ticket, by: "Reviewer")
        await fixture.decomposer.replace([
            Self.proposal(original.title, touches: ["Storage"],
                          paths: omitNewPaths ? nil : ["./Sources/NewStore.swift", "Resources/"]),
            other,
        ])
        try await fixture.breakDown()

        let reloaded = try await Self.reload(fixture.ledger)
        let kept = try #require(reloaded.nodes[oldLeaf.id])
        #expect(kept.ticket == oldLeaf.ticket)
        #expect(kept.testsDigest == "authored-tests")
        #expect(kept.gates.contains(.build))
        #expect(kept.phase == .ready)
        #expect(Set(kept.spec.predictedPaths) ==
                Set(omitNewPaths ? [] : ["Sources/NewStore.swift", "Resources"]))
        #expect(!kept.spec.predictedPaths.contains("Sources/OldStore.swift"))
        #expect(await fixture.tracker.createdChildren == 2, "Kept leaves retain their existing tickets.")
    }

    @Test
    func olderLedgersLoadLeavesWithoutPredictedPathsAndKeepTheirHashChainIntact() async throws {
        let store = InMemoryLedgerStore()
        store.append(try Self.legacyRecords())
        let ledger = try Ledger(store: store)
        let state = await ledger.workingState()
        let leaf = try #require(state.nodes[Self.rootSpec.id])
        #expect(leaf.spec.kind == .leaf)
        #expect(leaf.spec.touches == ["Storage"])
        #expect(leaf.spec.predictedPaths.isEmpty)
        #expect(await ledger.verifyChain().isIntact)
    }

    @Test
    func ticketPreviewShowsEachLeafsNormalizedPathsAfterItsTouchesAndOmitsAbsentPaths() async throws {
        let fixture = try Fixture(children: [
            Self.proposal("Store greeting", touches: ["Storage"],
                          paths: ["./Sources/Store.swift", "Resources/Greetings/"]),
            Self.proposal("Show greeting", touches: ["Display"], paths: ["Sources/Display"]),
            Self.proposal("Speak greeting", touches: ["Speech"], paths: nil),
        ])
        let preview = try await fixture.preview()
        let storeLine = try #require(preview.components(separatedBy: "\n").first { $0.contains("Store greeting") })
        let displayLine = try #require(preview.components(separatedBy: "\n").first { $0.contains("Show greeting") })
        let speechLine = try #require(preview.components(separatedBy: "\n").first { $0.contains("Speak greeting") })
        try Self.expectPaths(["Sources/Store.swift", "Resources/Greetings"], after: "Storage", in: storeLine)
        try Self.expectPaths(["Sources/Display"], after: "Display", in: displayLine)
        #expect(!speechLine.localizedCaseInsensitiveContains("paths"))
        #expect(!storeLine.contains("./Sources"))
        #expect(!storeLine.contains("Resources/Greetings/"))
        #expect(await fixture.ledger.workingState().nodes.isEmpty, "A preview still creates no nodes.")
    }

    @Test(arguments: [false, true])
    func singleLeafPreviewShowsPredictionsOnlyWhenTheLeafHasThem(hasPaths: Bool) async throws {
        let fixture = try Fixture(children: [
            Self.proposal(Self.rootSpec.title, touches: ["Storage"],
                          paths: hasPaths ? ["Sources/Store.swift"] : nil),
        ])
        let preview = try await fixture.preview()
        let leafLine = try #require(preview.components(separatedBy: "\n").first {
            $0.localizedCaseInsensitiveContains("touches")
        })
        if hasPaths {
            try Self.expectPaths(["Sources/Store.swift"], after: "Storage", in: leafLine)
        } else {
            #expect(!leafLine.localizedCaseInsensitiveContains("paths"))
        }
    }

    @MainActor @Test
    func workPaneRendererReadsAnExistingTouchSetAndAnExistingEmptyValue() async throws {
        let image = try await Self.detailImage(paths: [], links: ["GH-75-alpha", "GH-75-beta"])
        let touches = try Self.rowText("Touches", in: image)
        #expect(RenderedUI.shows("Storage", in: touches))
        Self.expectDash(in: try Self.rowText("Landed at", in: image))
        let links = try Self.rowText("Links", in: image)
        #expect(RenderedUI.shows("GH-75-alpha", in: links))
        #expect(RenderedUI.shows("GH-75-beta", in: links),
                "The row reader must include every line of an existing multiline row.")
    }

    @MainActor @Test
    func workPanePathsRowListsEveryPredictedPath() async throws {
        let image = try await Self.detailImage(paths: ["Sources/Store.swift", "Resources/Greetings"])
        let text = try Self.rowText("Paths", in: image)
        #expect(RenderedUI.shows("Sources/Store.swift", in: text))
        #expect(RenderedUI.shows("Resources/Greetings", in: text))
    }

    @MainActor @Test
    func workPanePathsRowShowsADashForALeafWithNoPredictions() async throws {
        let image = try await Self.detailImage(paths: [])
        Self.expectDash(in: try Self.rowText("Paths", in: image))
    }
}

extension GH_75Tests {
    static var rootSpec: NodeSpec {
        NodeSpec(id: "wn-GH-75", kind: .composite, title: "Greeting features", intent: "Greet the user",
                 acceptanceCriteria: ["A greeting is stored", "A greeting is visible"])
    }

    static var ticket: Ticket {
        Ticket(key: "GH-75", title: rootSpec.title, description: rootSpec.intent,
               acceptanceCriteria: rootSpec.acceptanceCriteria, createdBy: .human("Reviewer"))
    }

    static func proposal(_ title: String, touches: [String], paths: [String]?) -> ChildProposal {
        var proposal = ChildProposal(title: title, acceptanceCriteria: ["\(title) is available"], touches: touches)
        proposal.predictedPaths = paths
        return proposal
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func expectPaths(_ paths: [String], after component: String, in text: String) throws {
        let touchLabel = try #require(text.range(of: "touches", options: .caseInsensitive))
        let touch = try #require(text.range(of: component, range: touchLabel.upperBound..<text.endIndex))
        for path in paths {
            let shown = try #require(text.range(of: path), "Missing \(path) in:\n\(text)")
            #expect(shown.lowerBound >= touch.upperBound, "Paths follow the touch set.")
        }
    }

    static func reload(_ ledger: Ledger) async throws -> WorkingState {
        let records = await ledger.allRecords()
        let restored = try Hashing.decoder().decode([RecordedEvent].self, from: Hashing.canonicalJSON(records))
        let store = InMemoryLedgerStore()
        store.append(restored)
        let ledger = try Ledger(store: store)
        #expect(await ledger.verifyChain().isIntact)
        return await ledger.workingState()
    }

    @MainActor
    static func detailImage(paths: [String], links: [String] = []) async throws -> CGImage {
        var spec = rootSpec
        spec.kind = .leaf
        spec.touches = ["Storage"]
        spec.predictedPaths = paths
        let ledger = try Ledger()
        try await ledger.append([LedgerEvent(node: spec.id, by: .reconciler,
                                            kind: .nodeCreated(spec: spec, ticket: ticket.key))])
        try await ledger.append(links.map {
            LedgerEvent(node: spec.id, by: .reconciler,
                        kind: .linkAdded(TypedLink(from: spec.id, type: .dependsOn, to: $0)))
        })
        let model = HarnessViewModel()
        model.state = await ledger.workingState()
        let node = try #require(model.state.nodes[spec.id])
        let view = NodeDetail(node: node).environment(model)
            .frame(width: 650, height: 600).scaleEffect(2)
            .frame(width: 1300, height: 1200)
        let image = try RenderedUI.image(of: view, size: CGSize(width: 1300, height: 1200))
        let text = try RenderedUI.text(in: image).joined(separator: "\n")
        try #require(RenderedUI.shows("Touches", in: text) && RenderedUI.shows("Storage", in: text),
                     "The existing detail must be readable before checking Paths:\n\(text)")
        return image
    }

    @MainActor
    static func rowText(_ label: String, in image: CGImage) throws -> String {
        try RenderedUI.text(in: rowImage(label, in: image)).joined(separator: "\n")
    }

    @MainActor
    private static func rowImage(_ label: String, in image: CGImage) throws -> CGImage {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let labels = ["Ticket", "Phase", "Gates", "Links", "Touches", "Paths", "Test target",
                      "Attempts failed", "Reworks", "Landed at", "Tests fingerprint", "Spec hash"]
        var boxes: [String: CGRect] = [:]
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            for title in labels {
                if let range = candidate.string.range(of: title, options: [.anchored, .caseInsensitive]),
                   let box = try candidate.boundingBox(for: range) {
                    boxes[title] = box.boundingBox
                }
            }
        }
        let box = try #require(boxes[label], "Missing \(label) row in:\n\(recognized)")
        // Grid labels are vertically centered, so a multiline value can extend above and below its label.
        let top = boxes.values.filter { $0.minY > box.maxY }.map(\.minY).min() ?? 1
        let bottom = boxes.values.filter { $0.maxY < box.minY }.map(\.maxY).max() ?? 0
        let rect = CGRect(x: 0, y: (1 - top) * CGFloat(image.height),
                          width: CGFloat(image.width), height: (top - bottom) * CGFloat(image.height)).integral
        return try #require(image.cropping(to: rect))
    }

    private static func expectDash(in text: String) {
        #expect(text.contains { "–—-".contains($0) }, "Show an empty-value dash, not a blank row:\n\(text)")
    }
}
