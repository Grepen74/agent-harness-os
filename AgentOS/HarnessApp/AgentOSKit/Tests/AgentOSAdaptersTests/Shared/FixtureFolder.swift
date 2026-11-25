import Foundation

public enum FixtureFolder {
    /// Removes a test's folder while the workspace's trash may still be deleting retired working copies inside it: a
    /// file the trash deletes first makes one pass fail, so it tries again until the folder is gone.
    public static func remove(_ directory: URL) throws {
        var attempt = 0
        while true {
            do {
                try FileManager.default.removeItem(at: directory)
                return
            } catch {
                attempt += 1
                guard FileManager.default.fileExists(atPath: directory.path) else { return }
                if attempt >= 50 { throw error }
            }
        }
    }
}
