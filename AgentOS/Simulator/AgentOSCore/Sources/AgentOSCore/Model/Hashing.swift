import CryptoKit
import Foundation

enum Hashing {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ string: String) -> String { sha256(Data(string.utf8)) }

    /// Stable encoding: the same value always gives the same bytes, so hashes can be re-checked anywhere.
    static func canonicalJSON<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Fingerprint of every file below `directory` (path + content), ignoring build output.
    static func digest(of directory: URL) -> String {
        let base = directory.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return sha256("") }

        var files: [(path: String, data: Data)] = []
        while let url = enumerator.nextObject() as? URL {
            if [".build", ".swiftpm", "Package.resolved"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            files.append((relative, (try? Data(contentsOf: url)) ?? Data()))
        }

        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: file.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
