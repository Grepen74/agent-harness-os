import Foundation
import Synchronization

enum CopilotRuntimeVersion {
    /// Session construction is synchronous; keep the bounded process work off its calling executor.
    static func read(executable: String, in directory: URL) -> String {
        let version = Mutex("unknown")
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            defer { finished.signal() }
            do {
                let result = try await ProcessRunner.run(executable, ["--version"], in: directory, timeout: .seconds(10))
                guard result.status == 0,
                      let range = result.output.range(
                        of: #"\b[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\b"#,
                        options: .regularExpression)
                else {
                    NSLog("Could not determine the Copilot CLI version (exit %d); recording unknown.", result.status)
                    return
                }
                version.withLock { $0 = String(result.output[range]) }
            } catch {
                NSLog("Could not read the Copilot CLI version; recording unknown: %@", error.localizedDescription)
            }
        }
        finished.wait()
        return version.withLock { $0 }
    }
}
