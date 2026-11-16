// API contract: NodeSpec.predictedPaths: [String] (empty means missing) and Policy.avoidOverlappingWork: Bool
// control admission of ready leaves through the existing Reconciler round APIs.
// The idle-loop fixture repeats nonwaiting rounds until RoundReport.isIdle.
import AgentOSCore
import Testing

@Suite
struct GH_77Tests {
    @Test(arguments: [Phase.building, .checking, .landing])
    func overlappingReadyLeavesWaitThroughEveryInProgressPhase(phase: Phase) async throws {
        try await Self.withFixture(limit: 1) { f in
            try await f.blocker("blocker", phase: phase, paths: ["Sources/A"])
            try await f.leaf("leaf-held", paths: ["Sources/A/B.swift"])
            try await f.leaf("leaf-free", paths: ["Sources/Other.swift"])

            try await f.round()

            #expect(await f.reservedLeaves() == ["leaf-free"])
            #expect(await f.ledger.workingState().nodes["leaf-held"]?.phase == .ready)
        }
    }

    @Test
    func awaitingHumanReviewStillHoldsOverlappingWorkWithoutAnActiveAgent() async throws {
        try await Self.withFixture(limit: 1) { f in
            try await f.blocker("blocker", phase: .landing, paths: ["Sources/A"], humanReview: true)
            try await f.leaf("leaf-held", paths: ["Sources/A/B.swift"])
            try await f.leaf("leaf-free", paths: ["Sources/Other.swift"])
            let node = try #require(await f.ledger.workingState().nodes["blocker"])
            try #require(node.awaitingHumanReview && node.activeRun == nil)

            try await f.round()

            #expect(await f.reservedLeaves() == ["leaf-free"])
        }
    }

    @Test(arguments: [
        PathCase(["Sources/A.swift"], ["Sources/A.swift"], overlaps: true),
        PathCase(["Sources/A"], ["Sources/A/B.swift"], overlaps: true),
        PathCase(["Sources/A/B.swift"], ["Sources/A"], overlaps: true),
        PathCase(["Sources/A"], ["Sources/AB.swift"], overlaps: false),
        PathCase(["Sources/AB.swift"], ["Sources/A"], overlaps: false),
        PathCase(["Sources/A/B.swift"], ["Sources/A/C.swift"], overlaps: false),
        PathCase(["Docs/Guide.md", "Sources/A"], ["Tests/Own.swift", "Sources/A/B.swift"], overlaps: true),
    ])
    func pathsMatchInEitherDirectionOnWholeComponentsOnly(example: PathCase) async throws {
        try await Self.withFixture(limit: 1) { f in
            // Matching touches must not override disjoint, available path predictions.
            try await f.blocker("blocker", paths: example.busy, touches: ["Engine"])
            try await f.leaf("leaf-first", paths: example.ready, touches: ["Engine"])
            try await f.leaf("leaf-next", paths: ["Independent/File.swift"])

            try await f.round()

            #expect(await f.reservedLeaves() == [example.overlaps ? "leaf-next" : "leaf-first"])
        }
    }

    @Test(arguments: [
        TouchCase(nil, ["Engine"], ["Sources/A"], ["Engine"], overlaps: true),
        TouchCase(["Sources/A"], ["Engine"], nil, ["Engine"], overlaps: true),
        TouchCase([], ["UI", "Engine"], [], ["Engine", "Storage"], overlaps: true),
        TouchCase(nil, ["Engine"], ["Sources/A"], ["EngineTools"], overlaps: false),
        TouchCase(["Sources/A"], ["Engine"], nil, ["UI"], overlaps: false),
        TouchCase(nil, [], ["Sources/A"], ["Engine"], overlaps: false),
        TouchCase(["Sources/A"], ["Engine"], nil, [], overlaps: false),
        TouchCase(nil, [], nil, [], overlaps: false),
        TouchCase(["Sources/A"], [], nil, ["Engine"], overlaps: false),
        TouchCase(nil, ["Engine"], ["Sources/A"], [], overlaps: false),
    ])
    func missingPathsFallBackToSharedComponentNamesAndUnknownWorkNeverHolds(example: TouchCase) async throws {
        try await Self.withFixture(limit: 1) { f in
            try await f.blocker("blocker", paths: example.busyPaths, touches: example.busyTouches)
            try await f.leaf("leaf-first", paths: example.readyPaths, touches: example.readyTouches)
            try await f.leaf("leaf-next", paths: ["Independent/File.swift"])

            try await f.round()

            #expect(await f.reservedLeaves() == [example.overlaps ? "leaf-next" : "leaf-first"])
        }
    }

    @Test(arguments: Mode.allCases, [
        TouchCase(nil, ["Engine"], ["Sources/A"], ["Engine"], overlaps: true),
        TouchCase(["Sources/A"], ["Engine"], nil, ["Engine"], overlaps: true),
        TouchCase([], ["UI", "Engine"], [], ["Engine", "Storage"], overlaps: true),
        TouchCase(nil, ["Engine"], ["Sources/A"], ["EngineTools"], overlaps: false),
        TouchCase(nil, [], ["Sources/A"], ["Engine"], overlaps: false),
        TouchCase(["Sources/A"], ["Engine"], nil, [], overlaps: false),
        TouchCase(nil, [], nil, [], overlaps: false),
    ])
    func readyLeavesUseTouchFallbackAndOnlyTheLaterOverlapWaits(mode: Mode, example: TouchCase) async throws {
        try await Self.withFixture(limit: 2, expectedEntries: 2) { f in
            try await f.leaf("leaf-oldest", paths: example.busyPaths, touches: example.busyTouches)
            try await f.leaf("leaf-later", paths: example.readyPaths, touches: example.readyTouches)
            try await f.leaf("leaf-free", paths: ["Independent/File.swift"])
            try await f.leaf("leaf-over-capacity", paths: ["Other/File.swift"])

            f.start(mode)
            try await f.probe.filled.value()

            #expect(await f.reservedLeaves() == ["leaf-oldest", example.overlaps ? "leaf-free" : "leaf-later"])
            if example.overlaps {
                #expect(await f.ledger.workingState().nodes["leaf-later"]?.phase == .ready)
            }
        }
    }

    @Test(arguments: Mode.allCases)
    func heldLeavesUseNoSlotsAndTheEarliestOverlappingReadyLeafWins(mode: Mode) async throws {
        try await Self.withFixture(limit: 3, expectedEntries: 3) { f in
            try await f.leaf("leaf-oldest", paths: ["Sources/A"])
            try await f.leaf("leaf-held-one", paths: ["Sources/A/B.swift"])
            try await f.leaf("leaf-free-one", paths: ["Sources/B.swift"])
            try await f.leaf("leaf-held-two", paths: ["Sources/A"])
            try await f.leaf("leaf-free-two", paths: ["Sources/C.swift"])
            try await f.leaf("leaf-over-capacity", paths: ["Sources/D.swift"])

            f.start(mode)
            try await f.probe.filled.value()

            #expect(await f.reservedLeaves() == ["leaf-oldest", "leaf-free-one", "leaf-free-two"])
            let state = await f.ledger.workingState()
            #expect(state.nodes["leaf-held-one"]?.phase == .ready)
            #expect(state.nodes["leaf-held-two"]?.phase == .ready)
        }
    }

    @Test
    func reservationsAndStepsFromEarlierRoundsStillHoldOthersAndCountAgainstTheLimit() async throws {
        try await Self.withFixture(limit: 2) { f in
            try await f.leaf("leaf-oldest", paths: ["Sources/A"])
            try await f.round()
            try #require(await f.reservedLeaves() == ["leaf-oldest"])
            // Keep the first leaf before its claim, when phase alone cannot identify its reservation.
            try #require(await f.ledger.workingState().nodes["leaf-oldest"]?.activeRun == nil)
            try await f.leaf("leaf-held", paths: ["Sources/A/B.swift"])
            try await f.leaf("leaf-free", paths: ["Sources/B.swift"])
            try await f.leaf("leaf-over-capacity", paths: ["Sources/C.swift"])

            try await f.round()
            try await f.round()

            #expect(await f.reservedLeaves() == ["leaf-oldest", "leaf-free"])
        }
    }

    @Test
    func anAlreadyClaimedImplementerKeepsHoldingOverlappingWorkAcrossRounds() async throws {
        try await Self.withFixture(limit: 2, holdBeforeClaim: false, holdImplementer: true) { f in
            try await f.leaf("leaf-oldest", paths: ["Sources/A"])
            try await f.round()
            try await f.agents.entered.value()
            try #require(await f.ledger.workingState().nodes["leaf-oldest"]?.phase == .building)
            try await f.leaf("leaf-held", paths: ["Sources/A/B.swift"])
            try await f.leaf("leaf-free", paths: ["Sources/B.swift"])
            try await f.leaf("leaf-over-capacity", paths: ["Sources/C.swift"])

            try await f.round()
            try await f.round()

            #expect(await f.reservedLeaves() == ["leaf-oldest", "leaf-free"])
        }
    }

    @Test(arguments: Release.allCases)
    func heldWorkStartsInTheFirstFreeRoundOnlyAfterEveryOverlapStopsHolding(reason: Release) async throws {
        try await Self.withFixture(limit: 2) { f in
            if reason == .replanned {
                try await f.parent("parent-one")
                try await f.parent("parent-two")
            }
            try await f.blocker("blocker-one", parent: reason == .replanned ? "parent-one" : nil,
                                paths: ["Sources/A"])
            try await f.blocker("blocker-two", parent: reason == .replanned ? "parent-two" : nil,
                                paths: ["Sources/A/B.swift"])
            try await f.leaf("leaf-held", paths: ["Sources/A/B.swift"])
            try await f.round()
            try #require(!(await f.reservedLeaves()).contains("leaf-held"), "Initially overlapping work must be held")

            try await f.stopHolding("blocker-one", parent: "parent-one", reason: reason)
            try await f.round()
            try #require(!(await f.reservedLeaves()).contains("leaf-held"), "The second overlap still holds it")

            try await f.stopHolding("blocker-two", parent: "parent-two", reason: reason)
            try await f.round()

            #expect((await f.reservedLeaves()).contains("leaf-held"))
            #expect(await f.tracker.pendingSignals().isEmpty)
            let records = await f.ledger.allRecords()
            #expect(!records.contains { if case .signalAccepted = $0.event.kind { return true }; return false })
        }
    }

    @Test(arguments: Release.allCases)
    func nodesThatHaveStoppedBeingInProgressDoNotHoldReadyWork(reason: Release) async throws {
        try await Self.withFixture(limit: 1) { f in
            if reason == .replanned { try await f.parent("parent") }
            try await f.blocker("blocker", parent: reason == .replanned ? "parent" : nil, paths: ["Sources/A"])
            try await f.stopHolding("blocker", parent: "parent", reason: reason)
            try await f.leaf("leaf-ready", paths: ["Sources/A/B.swift"])

            try await f.round()

            #expect(await f.reservedLeaves() == ["leaf-ready"])
            let state = await f.ledger.workingState()
            let blocker = try #require(state.nodes["blocker"])
            switch reason {
            case .landed: #expect(blocker.phase == .proven)
            case .escalated: #expect(blocker.flags[.escalated] != nil)
            case .needsInput: #expect(blocker.flags[.needsInput] != nil)
            case .replanned: #expect(state.nodes["parent"]?.phase == .specified)
            case .closed: #expect(blocker.ticketClosed)
            }
        }
    }

    @Test(arguments: Mode.allCases, [true, false])
    func heldWorkDoesNotConsumeTheSlotKeptForAWaitingLanding(mode: Mode, settingOn: Bool) async throws {
        try await Self.withFixture(limit: 3, settingOn: settingOn, expectedEntries: 2, holdLanding: true) { f in
            try await f.queued("queued", paths: ["Sources/A"])
            try await f.leaf("leaf-first", paths: ["Sources/A/B.swift"])
            try await f.leaf("leaf-second", paths: ["Sources/B.swift"])
            try await f.leaf("leaf-third", paths: ["Sources/C.swift"])
            try await f.leaf("leaf-fourth", paths: ["Sources/D.swift"])
            f.start(mode)
            try await f.probe.filled.value()
            if mode != .waitingRound {
                try await f.workspace.landingEntered.value()
            }

            #expect(await f.reservedLeaves() == (settingOn
                ? ["leaf-second", "leaf-third"] : ["leaf-first", "leaf-second"]))
            if mode != .waitingRound {
                #expect(await f.reconciler.busyNodes.count == 3)
            }

            f.probe.release.resolve(.success(()))
            try await f.workspace.landingEntered.value()
        }
    }

    @Test(arguments: Mode.allCases, [true, false])
    func aSingleSlotIsKeptForLandingBeforeAnyReadyLeafCanStart(mode: Mode, settingOn: Bool) async throws {
        try await Self.withFixture(limit: 1, settingOn: settingOn, holdBeforeClaim: false) { f in
            try await f.queued("queued", paths: ["Sources/A"])
            try await f.leaf("leaf-first", paths: ["Independent/File.swift"])
            f.start(mode)
            try await f.finishRuns()
            try await f.drainAgents()
            try await f.round()
            try await f.drainAgents()

            let records = await f.ledger.allRecords()
            var landingPosition: Int?
            var startingPosition: Int?
            for record in records {
                switch (record.event.node, record.event.kind) {
                case ("queued", .landed):
                    landingPosition = record.position
                case ("leaf-first", .runStarted) where startingPosition == nil:
                    startingPosition = record.position
                default: break
                }
            }
            let landed = try #require(landingPosition)
            let started = try #require(startingPosition, "The ready leaf must start once landing frees the slot")
            #expect(landed < started)
        }
    }

    @Test(arguments: Mode.allCases)
    func disablingAvoidanceAdmitsReadyLeavesInCreationOrderDespitePathsOrTouches(mode: Mode) async throws {
        try await Self.withFixture(limit: 3, settingOn: false, expectedEntries: 3) { f in
            try await f.blocker("blocker", paths: ["Sources/A"], touches: ["Engine"])
            try await f.leaf("leaf-oldest", paths: ["Sources/A/B.swift"], touches: ["Engine"])
            try await f.leaf("leaf-second", paths: nil, touches: ["Engine"])
            try await f.leaf("leaf-third", paths: ["Sources/A"], touches: ["Engine"])
            try await f.leaf("leaf-over-capacity", paths: ["Independent/File.swift"])

            f.start(mode)
            try await f.probe.filled.value()

            #expect(await f.reservedLeaves() == ["leaf-oldest", "leaf-second", "leaf-third"])
        }
    }

    @Test(arguments: Mode.allCases)
    func controlledFixturesCanActuallyClaimFinishAndReachNeedsInput(mode: Mode) async throws {
        try await Self.withFixture(limit: 1, holdBeforeClaim: false) { f in
            try await f.leaf("leaf-control", paths: ["Independent/File.swift"])
            f.start(mode)
            try await f.finishRuns()
            try await f.drainAgents()

            let node = try #require(await f.ledger.workingState().nodes["leaf-control"])
            #expect(node.activeRun == nil)
            #expect(node.flags[.escalated] == nil)
            #expect(node.flags[.needsInput] != nil)
            #expect(f.agents.starts == ["leaf-control"])
        }
    }
}
