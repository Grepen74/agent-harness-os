import Foundation

public struct ExternalItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public let key: String
    public let title: String
    /// Who owns it, e.g. "Backend team". Outside the harness's control.
    public let owner: String
    public var delivered = false
}

/// What the harness needs to know about items owned by other systems or teams.
public protocol ExternalDependencySource: Sendable {
    func deliveredKeys() async -> Set<String>
}

/// A stand-in for another team's backlog or another system's release (e.g. a backend API).
/// In the app, a human marks items as delivered, mimicking the outside world.
/// Production: an adapter to that team's tracker or release feed; at system boundary level 3
/// the interface is fixed for agents (doc 01).
public actor MockExternalSystem: ExternalDependencySource {
    public nonisolated let fileURL: URL?
    private var store: [ExternalItem] = []

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? Hashing.decoder().decode([ExternalItem].self, from: data) {
            store = saved
        }
    }

    public func items() -> [ExternalItem] { store }

    public func add(key: String, title: String, owner: String) {
        guard !store.contains(where: { $0.key == key }) else { return }
        store.append(ExternalItem(key: key, title: title, owner: owner))
        save()
    }

    public func deliver(_ key: String) {
        guard let index = store.firstIndex(where: { $0.key == key }) else { return }
        store[index].delivered = true
        save()
    }

    public func deliveredKeys() -> Set<String> {
        Set(store.filter(\.delivered).map(\.key))
    }

    private func save() {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Hashing.canonicalJSON(store).write(to: fileURL, options: .atomic)
    }
}
