// API contract: AgentLog and ProcessRunner timestamp each persisted physical line when it is produced,
// while ProcessRunner continues to return unformatted output to callers that parse command results.

import AgentOSCore
import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_17_2Tests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "agentos-GH-17-2-\(UUID().uuidString)")

    @Test
    func everyAgentOutputLineIncludesItsProductionTime() throws {
        let log = try logFile(named: "agent.log")
        let producedAt = Date(timeIntervalSince1970: 12 * 60 * 60 + 34 * 60 + 56)

        AgentLog.append(
            "first line\nsecond line",
            to: log,
            producedAt: producedAt,
            timeZone: try #require(TimeZone(secondsFromGMT: 0))
        )

        #expect(try String(contentsOf: log, encoding: .utf8) == """
        [12:34:56] first line
        [12:34:56] second line

        """)
    }

    @Test
    func timestampsUseHHMMSSInTheUsersLocalTimeZone() throws {
        let log = try logFile(named: "local-time.log")
        let localTimeZone = try #require(TimeZone(secondsFromGMT: 5 * 60 * 60 + 45 * 60))

        AgentLog.append(
            "locally formatted",
            to: log,
            producedAt: Date(timeIntervalSince1970: 6),
            timeZone: localTimeZone
        )

        #expect(try String(contentsOf: log, encoding: .utf8) == "[05:45:06] locally formatted\n")
    }

    @Test
    func agentAndProcessLinesRetainTheirProductionTimestampsWhenReadLater() async throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let agentLog = try logFile(named: "retained-agent.log")
        AgentLog.append(
            "started",
            to: agentLog,
            producedAt: Date(timeIntervalSince1970: 1),
            timeZone: timeZone
        )
        AgentLog.append(
            "finished",
            to: agentLog,
            producedAt: Date(timeIntervalSince1970: 2),
            timeZone: timeZone
        )

        #expect(try String(contentsOf: agentLog, encoding: .utf8) == """
        [00:00:01] started
        [00:00:02] finished

        """)

        let processLog = try logFile(named: "retained-process.log")
        let result = try await ProcessRunner.run(
            "/bin/sh",
            ["-c", "printf 'early\\n'; /bin/sleep 2; printf 'late\\n'"],
            in: directory,
            log: processLog,
            timeZone: timeZone
        )
        let persistedLines = try String(contentsOf: processLog, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        #expect(result.output == "early\nlate\n")
        try #require(persistedLines.count == 2)
        #expect(persistedLines.allSatisfy { $0.wholeMatch(of: /^\[\d{2}:\d{2}:\d{2}\] .+$/) != nil })
        #expect(persistedLines[0].hasSuffix(" early"))
        #expect(persistedLines[1].hasSuffix(" late"))
        #expect(String(persistedLines[0].prefix(10)) != String(persistedLines[1].prefix(10)))
    }

    private func logFile(named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }
}
