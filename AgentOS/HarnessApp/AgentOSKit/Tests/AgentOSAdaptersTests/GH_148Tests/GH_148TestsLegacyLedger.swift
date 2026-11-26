import Foundation

extension GH_148Tests {
    // Frozen before adding testsRecorded; hashes must never be regenerated with the new encoder.
    static let legacyLedger = """
    {"event":{"at":"2026-11-01T12:00:00Z","by":{"human":{"_0":"Alice"}},"id":"00000000-0000-0000-0000-000000000001","kind":{"nodeCreated":{"spec":{"acceptanceCriteria":["Existing tests stay locked"],"dependsOn":[],"id":"wn-legacy-148","intent":"Keep existing locks","kind":"leaf","profile":"simple-app","title":"Legacy leaf","touches":["Engine"]},"ticket":"OLD-148"}},"node":"wn-legacy-148"},"hash":"ff19451807e5e4f23f029a0f990d29bf726401db737ecf03e7e47b52fe43c136","position":0,"previousHash":"0000000000000000000000000000000000000000000000000000000000000000"}
    {"event":{"at":"2026-11-01T12:00:00Z","by":{"human":{"_0":"Alice"}},"id":"00000000-0000-0000-0000-000000000002","kind":{"gateOpened":{"_0":"build"}},"node":"wn-legacy-148"},"hash":"81ab7686398d61c773f327c50d4567de7a4ded2eeeac8fae558ae6442f81d079","position":1,"previousHash":"ff19451807e5e4f23f029a0f990d29bf726401db737ecf03e7e47b52fe43c136"}
    {"event":{"at":"2026-11-01T12:00:00Z","by":{"reconciler":{}},"id":"00000000-0000-0000-0000-000000000003","kind":{"testsFixed":{"digest":"legacy-folder-digest"}},"node":"wn-legacy-148"},"hash":"62f6af4ad5dd0282712b7109643ba7a01f13a17f5d577e5d9f769394a00319e3","position":2,"previousHash":"81ab7686398d61c773f327c50d4567de7a4ded2eeeac8fae558ae6442f81d079"}
    {"event":{"at":"2026-11-01T12:00:00Z","by":{"reconciler":{}},"id":"00000000-0000-0000-0000-000000000004","kind":{"otherTestsUpdated":{"digest":"legacy-other-digest","files":["Tests/OlderTests/Older.swift"]}},"node":"wn-legacy-148"},"hash":"39cca94b27ef25d2a52213017cdaf12313bba5222adb11b8b8dd643b6ac19967","position":3,"previousHash":"62f6af4ad5dd0282712b7109643ba7a01f13a17f5d577e5d9f769394a00319e3"}
    {"event":{"at":"2026-11-01T12:00:00Z","by":{"reconciler":{}},"id":"00000000-0000-0000-0000-000000000005","kind":{"phaseChanged":{"to":"ready"}},"node":"wn-legacy-148"},"hash":"669d9d0084f78f3be450a8efe82fad6603e0e53229f3f8defa0271dd75d88aca","position":4,"previousHash":"39cca94b27ef25d2a52213017cdaf12313bba5222adb11b8b8dd643b6ac19967"}
    {"event":{"at":"2026-11-01T12:00:00Z","by":{"reconciler":{}},"id":"00000000-0000-0000-0000-000000000006","kind":{"catchUpSucceeded":{"main":"old-main","method":"automatic","newAgentOSMainTip":"old-tip"}},"node":"wn-legacy-148"},"hash":"2d00fc1679de73ab54865358606bc509f19e0f56681268e19a634aeaecd4636b","position":5,"previousHash":"669d9d0084f78f3be450a8efe82fad6603e0e53229f3f8defa0271dd75d88aca"}

    """
}
