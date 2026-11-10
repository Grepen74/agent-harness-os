// API contract: ProcessRunner safely manages many concurrently terminating processes and returns each result.

import Foundation
import Testing
@testable import AgentOSAdapters

@Suite
struct GH_16Tests {
    @Test
    func concurrentShortLivedProcessesCompleteReliably() async throws {
        for repetition in 0..<10 {
            let outputs = try await withThrowingTaskGroup(of: (Int, ProcessRunner.Result).self) { group in
                for process in 0..<24 {
                    group.addTask {
                        let result = try await ProcessRunner.run(
                            "/bin/echo",
                            ["\(repetition)-\(process)"],
                            in: FileManager.default.temporaryDirectory
                        )
                        return (process, result)
                    }
                }

                var outputs: [Int: String] = [:]
                for try await (process, result) in group {
                    #expect(result.status == 0)
                    outputs[process] = result.output
                }
                return outputs
            }

            #expect(outputs.count == 24)
            for process in 0..<24 {
                #expect(outputs[process] == "\(repetition)-\(process)\n")
            }
        }
    }
}
