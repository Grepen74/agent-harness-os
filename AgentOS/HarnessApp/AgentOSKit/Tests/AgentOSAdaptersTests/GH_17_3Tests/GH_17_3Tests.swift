// API contract: ChangesOutput timestamps each displayed line at refresh time and preserves timestamps
// for textually unchanged lines across later refreshes.

import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_17_3Tests {
    @Test
    func everyDisplayedChangesLineIncludesItsProductionTime() throws {
        var output = ChangesOutput(timeZone: try #require(TimeZone(secondsFromGMT: 0)))

        output.refresh(
            with: "Sources/App.swift | 2 +-\n+let greeting = \"Hello\"\n-let greeting = \"Hi\"",
            producedAt: Date(timeIntervalSince1970: 45_296)
        )

        #expect(output.text == """
            [12:34:56] Sources/App.swift | 2 +-
            [12:34:56] +let greeting = "Hello"
            [12:34:56] -let greeting = "Hi"
            """)
    }

    @Test
    func timestampsUseTheUsersLocalTimeZoneAndHHMMSSFormat() throws {
        let userTimeZone = try #require(TimeZone(secondsFromGMT: 5 * 3_600 + 30 * 60))
        var output = ChangesOutput(timeZone: userTimeZone)

        output.refresh(with: "No changes since main yet.", producedAt: Date(timeIntervalSince1970: 0))

        #expect(output.text == "[05:30:00] No changes since main yet.")
    }

    @Test
    func refreshTimestampsNewLinesWithoutRetimestampingUnchangedLines() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var output = ChangesOutput(timeZone: timeZone)
        output.refresh(
            with: "Sources/App.swift | 1 +\n+let greeting = \"Hello\"",
            producedAt: Date(timeIntervalSince1970: 0)
        )

        output.refresh(
            with: "Sources/App.swift | 1 +\n+let greeting = \"Hello, world\"\n+let farewell = \"Goodbye\"",
            producedAt: Date(timeIntervalSince1970: 65)
        )

        #expect(output.text == """
            [00:00:00] Sources/App.swift | 1 +
            [00:01:05] +let greeting = "Hello, world"
            [00:01:05] +let farewell = "Goodbye"
            """)
    }
}
