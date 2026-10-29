import Foundation

/// One result of the readiness scan (doc 01, "Onboarding a repo"): a gap or a fact about the repo,
/// with a suggested fix.
public struct Finding: Codable, Sendable, Hashable, Identifiable {
    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        /// Agents can't work here safely yet.
        case blocker
        /// Agents can work, but will likely do it badly or cause friction.
        case warning
        /// Worth knowing.
        case info

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// Which check produced it, e.g. `agents.instructions`.
    public let check: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public let suggestion: String?

    public var id: String { "\(check)|\(title)" }

    public init(check: String, severity: Severity, title: String, detail: String = "", suggestion: String? = nil) {
        self.check = check
        self.severity = severity
        self.title = title
        self.detail = detail
        self.suggestion = suggestion
    }
}

/// The result of one readiness scan of a repo's default branch.
public struct ReadinessScan: Codable, Sendable, Equatable {
    /// The branch the harness works from, if one was found.
    public let branch: String?
    public let commit: String?
    /// Most severe first.
    public let findings: [Finding]

    public init(branch: String?, commit: String?, findings: [Finding]) {
        self.branch = branch
        self.commit = commit
        self.findings = findings.sorted { $0.severity < $1.severity }
    }

    public func count(_ severity: Finding.Severity) -> Int { findings.filter { $0.severity == severity }.count }

    /// No blockers: agents may start work (warnings are accepted).
    public var isReady: Bool { count(.blocker) == 0 }

    public var summary: String {
        let counts = Finding.Severity.allCases.map { severity in
            let n = count(severity)
            return "\(n) \(severity.rawValue)\(n == 1 || severity == .info ? "" : "s")"
        }
        return counts.joined(separator: ", ")
    }
}
