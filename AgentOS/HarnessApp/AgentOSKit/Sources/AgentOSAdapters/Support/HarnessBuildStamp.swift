import AgentOSCore
import Foundation

/// Build-time provenance from the app bundle, never from the repository being worked on.
public enum HarnessBuildStamp {
    public static let current: HarnessBuild = {
        do {
            return try recordedBuild(from: Bundle.main.url(forResource: "harness-build", withExtension: "json"))
        } catch {
            NSLog("Could not read the harness build stamp; recording unknown: %@", error.localizedDescription)
            return HarnessBuild(commit: nil, modified: false)
        }
    }()

    public static func recordedBuild(from url: URL?) throws -> HarnessBuild {
        guard let url else { return HarnessBuild(commit: nil, modified: false) }
        do {
            return try JSONDecoder().decode(HarnessBuild.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return HarnessBuild(commit: nil, modified: false)
        }
    }
}
