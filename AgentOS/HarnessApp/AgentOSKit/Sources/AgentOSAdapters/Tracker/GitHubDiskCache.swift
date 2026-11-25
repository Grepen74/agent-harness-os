import Foundation
import Synchronization

/// What was read from GitHub, kept in the harness's storage so a new launch reads again only the issues that changed
/// since. Read once; a file that can't be read is ignored (everything is read again).
final class GitHubDiskCache<Value: Codable>: Sendable {
    let file: URL
    private let loaded = Mutex(false)

    init(file: URL) {
        self.file = file
    }

    /// The stored value the first time only; nil after that, or when there is none.
    func loadOnce() -> Value? {
        let first = loaded.withLock { loaded in
            defer { loaded = true }
            return !loaded
        }
        guard first, let data = try? Data(contentsOf: file) else { return nil }
        return try? Self.decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let data = try? Self.encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
