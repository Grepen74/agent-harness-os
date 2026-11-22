import Foundation

/// Session-scoped permissions, independent of whether an issue's comments changed.
actor GitHubCommentPermissions {
    struct Decision: Sendable {
        let allowed: Bool
        let problem: String?
    }

    private struct Permission: Decodable {
        let permission: String
    }

    private let repo: String
    private let transport: any GitHubTransport
    private let refreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: (checkedAt: Date, decision: Decision)] = [:]
    private var requests: [String: Task<Decision, Never>] = [:]

    init(repo: String, transport: any GitHubTransport, refreshInterval: Duration,
         now: @escaping @Sendable () -> Date) {
        self.repo = repo
        self.transport = transport
        let components = refreshInterval.components
        self.refreshInterval = Double(components.seconds) + Double(components.attoseconds) / 1e18
        self.now = now
    }

    func permission(for login: String) async -> Decision {
        if let cached = cache[login], now().timeIntervalSince(cached.checkedAt) < refreshInterval {
            return cached.decision
        }
        if let request = requests[login] { return await request.value }
        cache[login] = nil
        let checkedAt = now()
        let request = Task { [repo, transport] in
            do {
                let encoded = login.addingPercentEncoding(withAllowedCharacters: .alphanumerics
                    .union(CharacterSet(charactersIn: "-._~"))) ?? login
                let data = try await transport.request(
                    "GET", "repos/\(repo)/collaborators/\(encoded)/permission", body: nil)
                let permission = try JSONDecoder().decode(Permission.self, from: data).permission
                return Decision(allowed: ["write", "maintain", "admin"].contains(permission), problem: nil)
            } catch {
                return Decision(allowed: false, problem: "Reading repository permission for \(login): \(error)")
            }
        }
        requests[login] = request
        let decision = await request.value
        requests[login] = nil
        if decision.problem == nil { cache[login] = (checkedAt, decision) }
        return decision
    }
}
