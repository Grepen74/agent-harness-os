// Expected API: existing NodeSpec.integration, Planner.childSpecs, CopilotTestAuthor.prompt(for:),
// AgentTask.spec.touches, and Reconciler.runRound(waitForAgents:) with RepositoryWorkspace.
// Integration scope is delivered to the implementer through its task, including composite descendants.
// Reviewer-only AC5: real-repo-mode.md explains when integration children are added and their wait/scope/proof.
// Concept doc 02 section 5 describes the tree-owned seam-fixing leaf and defers empty/partial integration
// and integrates links. These documentation requirements are checked against the diff, not by tests.
import AgentOSAdapters
import AgentOSCore
import AgentOSTestSupport
import Foundation
import Testing

@Suite struct GH_167Tests {
    @Test(arguments: [false, true])
    func realGitIntegrationAuthorSeesEverySiblingsLandedWork(existingWorktree: Bool) async throws {
        try await Self.withFixture { fixture in
            let tree = try await Self.standardTree(in: fixture)
            if existingWorktree {
                try await fixture.workspace.prepare()
                let from = try await fixture.workspace.prepareRequirementBranch(
                    for: NodeIdentity(ticketKey: tree.ticket, nodeID: tree.parent.id),
                    leaves: [tree.producer.id, tree.consumer.id, tree.integration.id])
                if let from {
                    try await fixture.record(tree.parent.id, [
                        .requirementBranchCreated(branch: "agentos/\(tree.ticket)", from: from)
                    ])
                }
                let stale = try await fixture.workspace.createWorktree(for: tree.integration.id)
                #expect(try await Self.command("sh workflow.sh", in: stale).output == "pending\n")
            }

            try await fixture.settle()

            let observed = try #require(await fixture.agents.authored[tree.integration.id])
            #expect(observed.output == "hello world\n",
                    "The author's public workflow must already use both siblings' real landed code.")
            #expect(observed.testPassed, "A genuine combined test can already pass when it is written.")
            #expect(observed.head == observed.requirementHead,
                    "Authoring starts from the current requirement branch, not main or an earlier leaf base.")
            let state = await fixture.ledger.workingState()
            for sibling in [tree.producer, tree.consumer] {
                let landed = try #require(state.nodes[sibling.id]?.landedCommit)
                #expect(try await Self.isAncestor(landed, of: observed.head, in: fixture.repo),
                        "The test-author worktree must contain \(sibling.title)'s actual landed commit.")
            }
        }
    }

    @Test func integrationAuthorPromptExplainsCombinedPublicTestsMayAlreadyPass() throws {
        let ordinary = Self.promptTask(integration: false)
        let marked = Self.promptTask(integration: true)
        let prompt = Self.instructions(CopilotTestAuthor.prompt(for: marked))
        let control = Self.instructions(CopilotTestAuthor.prompt(for: ordinary))
        try #require(Self.matches(control, #"test author agent"#),
                     "The instruction extraction and matcher must recognize existing prompt text.")

        #expect(Self.matches(prompt, #"integration (item|child|work item|tests|test)"#),
                "The author must be told this item has an integration purpose.")
        #expect(Self.matches(prompt, #"sibling[^.]*(landed|work together|combined)|landed[^.]*sibling"#),
                "Tests must drive the siblings' landed work together.")
        #expect(Self.matches(prompt, #"public (entry points|entr[yi]points|apis|interfaces)"#))
        #expect(Self.matches(prompt, #"(rather than|instead of|not|never|don't|do not)[^.]*retest[^.]*(child|sibling)|without retesting[^.]*(child|sibling)"#),
                "Combined observations replace retesting the individual children.")
        #expect(Self.matches(prompt, #"tests[^.]*(may|might|can|could) already pass|already.pass[^.]*tests|tests[^.]*pass (already|unchanged)"#),
                "Already-passing integration tests are valid.")
        #expect(Self.matches(prompt, #"(not|never|don't|do not|mustn't)[^.]*(invent|manufacture|add|write|create)[^.]*tests?[^.]*fail"#),
                "The prompt must explicitly forbid inventing tests just to make them fail.")
    }

    @Test(arguments: [false, true])
    func ordinaryAuthorPromptHasNoIntegrationSpecificInstructions(explicitFalse: Bool) throws {
        var task = Self.promptTask(integration: false)
        if explicitFalse {
            var object = try #require(
                JSONSerialization.jsonObject(with: Hashing.canonicalJSON(task.spec)) as? [String: Any])
            object["integration"] = false
            let spec = try JSONDecoder().decode(
                NodeSpec.self, from: JSONSerialization.data(withJSONObject: object))
            task = Self.promptTask(spec: spec)
        }
        let prompt = Self.instructions(CopilotTestAuthor.prompt(for: task))
        #expect(!Self.matches(prompt, #"integration (item|child|work item|tests|test)"#))
        #expect(!Self.matches(prompt, #"sibling[^.]*landed|landed[^.]*sibling"#))
        #expect(!Self.matches(prompt, #"tests[^.]*(may|might|can|could) already pass|tests[^.]*pass unchanged"#))
        #expect(!Self.matches(prompt, #"(invent|manufacture)[^.]*tests?[^.]*fail"#))
    }

    @Test func integrationImplementerScopeIncludesEveryCompositeDescendantButOrdinaryScopeStaysOwn() async throws {
        try await Self.withFixture { fixture in
            await fixture.agents.stopAfterScopeCapture()
            let parent = Self.spec("parent", kind: .composite, touches: ["Parent"])
            try await fixture.add(parent, phase: .split, gates: [.breakdown])
            let proposals = [
                ChildProposal(title: "Producer", acceptanceCriteria: ["The producer emits hello"],
                              touches: ["Producer"], predictedPaths: ["Sources/Producer"]),
                ChildProposal(title: "Consumer subtree", acceptanceCriteria: ["The consumer formats greetings"],
                              touches: ["ConsumerComposite"], predictedPaths: ["Sources/Consumer"]),
                ChildProposal(title: "Combined workflow", acceptanceCriteria: ["The workflow says hello world"],
                              touches: ["Seams"], predictedPaths: ["workflow.sh"], integration: true)
            ]
            let planned = Planner.childSpecs(parent: parent, proposals: proposals)
            let producer = planned[0]
            var composite = planned[1]
            composite.kind = .composite
            let integration = planned[2]
            try await fixture.add(producer, gates: [.build])
            try await fixture.add(composite, phase: .proven)
            let consumer = Self.spec("consumer", parent: composite.id, touches: ["Consumer"])
            let nested = Self.spec("nested", parent: composite.id, kind: .composite, touches: ["NestedComposite"])
            let deep = Self.spec("deep", parent: nested.id, touches: ["DeepAdapter", "Consumer"])
            try await fixture.add(consumer, phase: .proven)
            try await fixture.add(nested, phase: .proven)
            try await fixture.add(deep, phase: .proven)
            try await fixture.add(integration, gates: [.build])
            try await fixture.add(Self.spec("unrelated", touches: ["OtherRequirement"]), phase: .proven)

            try await fixture.settle()

            let ordinaryTask = try #require(await fixture.agents.implemented[producer.id])
            #expect(Set(ordinaryTask.spec.touches) == Set(producer.touches),
                    "An ordinary child receives only its own declared touches.")
            let task = try #require(await fixture.agents.implemented[integration.id])
            let expected = Set(["Seams", "Producer", "ConsumerComposite", "Consumer", "NestedComposite", "DeepAdapter"])
            #expect(Set(task.spec.touches) == expected,
                    "Scope includes sibling composites and all descendants, even deeper than one level.")
            #expect(!task.spec.touches.contains("Parent"))
            #expect(!task.spec.touches.contains("OtherRequirement"))
        }
    }

    @Test func alreadySatisfiedIntegrationTestsAreVerifiedAndLandedBeforeTheParentIsProven() async throws {
        try await Self.withFixture { fixture in
            let tree = try await Self.standardTree(in: fixture)
            try await fixture.settle()
            let before = await fixture.ledger.workingState()
            #expect(before.nodes[tree.producer.id]?.phase == .proven)
            #expect(before.nodes[tree.consumer.id]?.phase == .proven)
            #expect(before.nodes[tree.integration.id]?.phase == .ready)
            #expect(before.nodes[tree.parent.id]?.phase == .split,
                    "Ordinary children's proofs alone cannot complete the parent.")
            #expect(await fixture.agents.implemented[tree.integration.id] == nil,
                    "Only the human build gate authorizes the integration implementer.")
            let directory = fixture.workspace.worktree(for: tree.integration.id)
            let testsCommit = try await fixture.workspace.head(of: directory)
            let testsPath = fixture.workspace.testFolder(for: tree.integration) + "/check.sh"
            let testsBefore = try await Self.git(["show", "\(testsCommit):\(testsPath)"], in: fixture.repo)

            try await fixture.record(tree.integration.id, [.gateOpened(.build)])
            try await fixture.settle()

            let after = await fixture.ledger.workingState()
            let integration = try #require(after.nodes[tree.integration.id])
            let submission = try #require(integration.lastSubmission)
            #expect(try await Self.git(["show", "\(submission.commit):\(testsPath)"], in: fixture.repo) == testsBefore,
                    "The submitted candidate retains the author's tests, including after a legitimate rebase.")
            let submittedFiles = try await Self.git(
                ["diff-tree", "--no-commit-id", "--name-only", "-r", submission.commit], in: fixture.repo)
            #expect(submittedFiles == testsPath,
                    "The alreadySatisfied candidate is the tests-only commit, not an invented implementation.")
            #expect(integration.evidence.contains {
                $0.passed && $0.commit == submission.commit && $0.builtBy == submission.run && $0.checkedBy != submission.run
            }, "An independent verifier must check the tests-only submission.")
            let landed = try #require(integration.landedCommit)
            #expect(try await Self.isAncestor(submission.commit, of: landed, in: fixture.repo))
            #expect(try await Self.git(["show", "agentos/\(tree.ticket):\(testsPath)"], in: fixture.repo) == testsBefore)
            #expect(integration.phase == .proven)
            #expect(after.nodes[tree.parent.id]?.phase == .proven)
            #expect(await fixture.agents.unchangedIntegrationChecks[tree.integration.id]?.passed == true,
                    "The fake implementer ran the real combined test without editing it or production code.")
            let records = await fixture.ledger.allRecords()
            let integrationProof = try #require(records.first {
                $0.event.node == tree.integration.id && Self.proves($0.event.kind)
            })
            let parentProof = try #require(records.first {
                $0.event.node == tree.parent.id && Self.proves($0.event.kind)
            })
            #expect(parentProof.position > integrationProof.position)
        }
    }

    @Test func fixturePublicCommandsAndOrdinaryLeafFlowWorkWithoutIntegrationSupport() async throws {
        try await Self.withFixture { fixture in
            #expect(try await Self.command("sh workflow.sh", in: fixture.repo).output == "pending\n")
            let producer = Self.spec("producer", title: "Producer", touches: ["Producer"])
            try await fixture.add(producer, gates: [.breakdown, .build])
            try await fixture.settle()
            let node = try #require(await fixture.ledger.workingState().nodes[producer.id])
            #expect(node.phase == .proven, "\(node.flags) \(node.recentFailures)")
            let observation = try #require(await fixture.agents.authored[producer.id])
            #expect(!observation.testPassed, "The existing runner must detect a legitimately unmet producer criterion.")
            #expect(node.evidence.contains { $0.passed },
                    "The same runner must pass after the ordinary implementer delivers it.")
            try #require(node.landedCommit != nil)
        }
    }
}
