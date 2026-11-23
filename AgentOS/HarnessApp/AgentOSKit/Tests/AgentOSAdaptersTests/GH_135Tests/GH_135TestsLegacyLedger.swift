import AgentOSCore
import Foundation
import Testing

extension GH_135Tests {
    @Test
    func preCatalogLedgerEventsStillDecodeAndRestoreTheirPhasesFlagsGatesSignalsAndActors() async throws {
        let bytes = Data(Self.preCatalogEvents.utf8)
        let events = try JSONDecoder().decode([LedgerEvent].self, from: bytes)
        let store = InMemoryLedgerStore()
        let ledger = try Ledger(store: store)
        try await ledger.append(events)
        let restored = try Ledger(store: store)
        let node = try #require(await restored.workingState().nodes["wn-legacy"])
        #expect(node.phase == .proven)
        #expect(node.spec.kind == .leaf)
        #expect(node.spec.predictedPaths.isEmpty)
        #expect(node.spec.after == nil)
        #expect(node.gates.contains(.breakdown))
        #expect(node.gates.contains(.build))
        #expect(node.flags.isEmpty)
        #expect(node.activeRun == nil)
        #expect(await restored.verifyChain().isIntact)
        for phase in [Phase.specified, .split, .ready, .building, .checking, .landing, .proven] {
            #expect(events.contains {
                if case .phaseChanged(to: phase) = $0.kind { return true }
                return false
            })
        }
        for role in [AgentRole.decomposer, .testAuthor, .implementer, .verifier, .diagnoser] {
            #expect(events.contains {
                if case .runStarted(_, role: role) = $0.kind { return true }
                return false
            })
        }
        for command in [HarnessCommand.preview, .breakdown, .build, .go, .retry, .retest, .replan] {
            #expect(events.contains {
                if case .signalAccepted(_, command: command, _) = $0.kind { return true }
                return false
            })
        }
        let originalJSON = try JSONSerialization.jsonObject(with: bytes) as? NSArray
        let reencodedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(events)) as? NSArray
        #expect(try #require(originalJSON) == #require(reencodedJSON),
                "CaseIterable/catalog additions must not change legacy event payloads")
    }

    // Frozen event JSON, not produced by today's encoder: omitted optional fields match older ledgers.
    private static let preCatalogEvents = """
    [
      {"id":"00000000-0000-0000-0000-000000000001","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,
       "kind":{"nodeCreated":{"spec":{"id":"wn-legacy","kind":"leaf","title":"Legacy requirement",
       "intent":"Existing event format","acceptanceCriteria":["Old events replay"],"touches":["Core"],
       "dependsOn":[],"profile":"simple-app"},"ticket":"OLD-1"}}},
      {"id":"00000000-0000-0000-0000-000000000002","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,"kind":{"gateOpened":{"_0":"breakdown"}}},
      {"id":"00000000-0000-0000-0000-000000000003","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,"kind":{"gateOpened":{"_0":"build"}}},
      {"id":"00000000-0000-0000-0000-000000000004","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"phaseChanged":{"to":"specified"}}},
      {"id":"00000000-0000-0000-0000-000000000005","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"phaseChanged":{"to":"split"}}},
      {"id":"00000000-0000-0000-0000-000000000006","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"phaseChanged":{"to":"ready"}}},
      {"id":"00000000-0000-0000-0000-000000000007","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"phaseChanged":{"to":"building"}}},
      {"id":"00000000-0000-0000-0000-000000000008","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"phaseChanged":{"to":"checking"}}},
      {"id":"00000000-0000-0000-0000-000000000009","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"phaseChanged":{"to":"landing"}}},
      {"id":"00000000-0000-0000-0000-000000000010","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"phaseChanged":{"to":"proven"}}},
      {"id":"00000000-0000-0000-0000-000000000011","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"flagSet":{"_0":"escalated","reason":"Legacy escalation"}}},
      {"id":"00000000-0000-0000-0000-000000000012","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,"kind":{"flagCleared":{"_0":"escalated"}}},
      {"id":"00000000-0000-0000-0000-000000000013","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"flagSet":{"_0":"blocked","reason":"Legacy dependency"}}},
      {"id":"00000000-0000-0000-0000-000000000014","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"flagCleared":{"_0":"blocked"}}},
      {"id":"00000000-0000-0000-0000-000000000015","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"flagSet":{"_0":"needs input","reason":"Legacy questions"}}},
      {"id":"00000000-0000-0000-0000-000000000016","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,"kind":{"flagCleared":{"_0":"needs input"}}},
      {"id":"00000000-0000-0000-0000-000000000017","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"runStarted":{"run":"old-decomposer","role":"decomposer"}}},
      {"id":"00000000-0000-0000-0000-000000000018","node":"wn-legacy","by":{"agent":{"run":"old-decomposer","role":"decomposer"}},"at":0,"kind":{"runFinished":{"run":"old-decomposer","outcome":"finished"}}},
      {"id":"00000000-0000-0000-0000-000000000019","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"runStarted":{"run":"old-tests","role":"testAuthor"}}},
      {"id":"00000000-0000-0000-0000-000000000020","node":"wn-legacy","by":{"agent":{"run":"old-tests","role":"testAuthor"}},"at":0,"kind":{"runFinished":{"run":"old-tests","outcome":"finished"}}},
      {"id":"00000000-0000-0000-0000-000000000021","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"runStarted":{"run":"old-build","role":"implementer"}}},
      {"id":"00000000-0000-0000-0000-000000000022","node":"wn-legacy","by":{"agent":{"run":"old-build","role":"implementer"}},"at":0,"kind":{"runFinished":{"run":"old-build","outcome":"finished"}}},
      {"id":"00000000-0000-0000-0000-000000000023","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"runStarted":{"run":"old-check","role":"verifier"}}},
      {"id":"00000000-0000-0000-0000-000000000024","node":"wn-legacy","by":{"agent":{"run":"old-check","role":"verifier"}},"at":0,"kind":{"runFinished":{"run":"old-check","outcome":"finished"}}},
      {"id":"00000000-0000-0000-0000-000000000025","node":"wn-legacy","by":{"reconciler":{}},"at":0,"kind":{"runStarted":{"run":"old-diagnosis","role":"diagnoser"}}},
      {"id":"00000000-0000-0000-0000-000000000026","node":"wn-legacy","by":{"agent":{"run":"old-diagnosis","role":"diagnoser"}},"at":0,"kind":{"runFinished":{"run":"old-diagnosis","outcome":"finished"}}},
      {"id":"00000000-0000-0000-0000-000000000027","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,"kind":{"signalAccepted":{"ticket":"OLD-1","command":"preview","reply":"accepted"}}},
      {"id":"00000000-0000-0000-0000-000000000028","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,"kind":{"signalAccepted":{"ticket":"OLD-1","command":"breakdown","reply":"accepted"}}},
      {"id":"00000000-0000-0000-0000-000000000029","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,"kind":{"signalAccepted":{"ticket":"OLD-1","command":"build","reply":"accepted"}}},
      {"id":"00000000-0000-0000-0000-000000000030","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,"kind":{"signalAccepted":{"ticket":"OLD-1","command":"go","reply":"accepted"}}},
      {"id":"00000000-0000-0000-0000-000000000031","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,"kind":{"signalAccepted":{"ticket":"OLD-1","command":"retry","reply":"accepted"}}},
      {"id":"00000000-0000-0000-0000-000000000032","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,"kind":{"signalAccepted":{"ticket":"OLD-1","command":"retest","reply":"accepted"}}},
      {"id":"00000000-0000-0000-0000-000000000033","node":"wn-legacy","by":{"human":{"_0":"Alice"}},"at":0,"kind":{"signalAccepted":{"ticket":"OLD-1","command":"replan","reply":"accepted"}}}
    ]
    """
}
