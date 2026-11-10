import AgentOSCore
import Foundation

public protocol MainTipRepository: Sendable {
    func localMainTip() async throws -> String
}

public enum MainBaselineTrigger: String, Sendable, Equatable {
    case mainMoved = "main moved"
    case scan
    case manual
}

public struct MainBaselineRequest: Sendable {
    public let commit: String
    public let trigger: MainBaselineTrigger
    public let fullLog: URL
    private let logReporter: @Sendable (String) async -> Void

    public init(
        commit: String,
        trigger: MainBaselineTrigger,
        fullLog: URL,
        reportLogLine: @escaping @Sendable (String) async -> Void
    ) {
        self.commit = commit
        self.trigger = trigger
        self.fullLog = fullLog
        self.logReporter = reportLogLine
    }

    public func reportLogLine(_ line: String) async {
        await logReporter(line)
    }
}

public struct BaselineRunResult: Sendable, Equatable {
    public let passed: Bool
    public let summary: String
    public let seconds: Int
    public let log: URL
    public let latestLogLine: String?

    public init(passed: Bool, summary: String, seconds: Int, log: URL, latestLogLine: String?) {
        self.passed = passed
        self.summary = summary
        self.seconds = seconds
        self.log = log
        self.latestLogLine = latestLogLine
    }
}

public struct ComparedMainCommits: Sendable, Equatable {
    public let lastBased: String
    public let observed: String

    public init(lastBased: String, observed: String) {
        self.lastBased = lastBased
        self.observed = observed
    }
}

public enum MainBaselineLedgerEvent: Sendable, Equatable {
    case baselineStarted(commit: String, trigger: MainBaselineTrigger)
    case baselineFinished(commit: String, passed: Bool, trigger: MainBaselineTrigger)
}

public enum MainBaselineAction: Sendable, Equatable {
    case stop
    case retry
    case dismiss
}

public struct MainBaselineBanner: Sendable, Equatable {
    public let title: String
    public let message: String
    public let latestLogLine: String?
    public let fullLog: URL?
    public let actions: [MainBaselineAction]
}

public struct MainBaselinePresentation: Sendable, Equatable {
    public enum Severity: Sendable, Equatable {
        case blocker
        case warning
        case info
    }

    public let severity: Severity
    public let message: String
    public let log: URL?
    public let actions: [MainBaselineAction]

    public static func missing(mainCommit: String, commitsBehind: Int, workExists: Bool) -> Self {
        if workExists {
            return .init(
                severity: .warning,
                message: "agentos/main is \(commitsBehind) commits behind main; catching up waits for a baseline",
                log: nil,
                actions: []
            )
        }
        return .init(
            severity: .blocker,
            message: "Baseline not checked at \(short(mainCommit))",
            log: nil,
            actions: []
        )
    }

    public static func failed(mainCommit: String, log: URL) -> Self {
        .init(
            severity: .warning,
            message: "Baseline fails on main at \(short(mainCommit))",
            log: log,
            actions: [.retry, .dismiss]
        )
    }

    public static func running(mainCommit: String) -> Self {
        .init(
            severity: .warning,
            message: "main moved to \(short(mainCommit)); baseline running\u{2026}",
            log: nil,
            actions: [.stop]
        )
    }

    public static func passed(mainCommit _: String, seconds: Int) -> Self {
        .init(
            severity: .info,
            message: "Baseline passed in \(duration(seconds)); catching up queued",
            log: nil,
            actions: []
        )
    }

    private static func short(_ commit: String) -> String {
        String(commit.prefix(8))
    }

    private static func duration(_ seconds: Int) -> String {
        String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }
}

public actor MainBaselineCoordinator {
    private struct Pending: Sendable {
        let commit: String
        let trigger: MainBaselineTrigger
    }

    private struct Running: Sendable {
        let commit: String
        let trigger: MainBaselineTrigger
        let startedAt: Date
        let fullLog: URL
        var latestLogLine: String?
    }

    public let lastBasedMainCommit: String
    private let repository: any MainTipRepository
    private let runner: @Sendable (MainBaselineRequest) async -> BaselineRunResult
    private let now: @Sendable () -> Date
    private var running: Running?
    private var pending: Pending?
    private var checkedCommits: Set<String> = []

    public private(set) var comparedMainCommits: [ComparedMainCommits] = []
    private var recordedLedgerEvents: [MainBaselineLedgerEvent] = []
    public private(set) var lastObservationError: String?

    public var ledgerEvents: [MainBaselineLedgerEvent] {
        get async {
            await Task.yield()
            return recordedLedgerEvents
        }
    }

    public init(
        lastBasedMainCommit: String,
        repository: any MainTipRepository,
        runner: @escaping @Sendable (MainBaselineRequest) async -> BaselineRunResult,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.lastBasedMainCommit = lastBasedMainCommit
        self.repository = repository
        self.runner = runner
        self.now = now
    }

    public func reconcile() async {
        do {
            let observed = try await repository.localMainTip()
            lastObservationError = nil
            comparedMainCommits.append(.init(lastBased: lastBasedMainCommit, observed: observed))
            if observed != lastBasedMainCommit {
                schedule(commit: observed, trigger: .mainMoved)
            }
            await Task.yield()
        } catch {
            lastObservationError = String(describing: error)
        }
    }

    public func requestBaseline(commit: String, trigger: MainBaselineTrigger) async {
        schedule(commit: commit, trigger: trigger)
        await Task.yield()
    }

    public func banner(at date: Date) -> MainBaselineBanner? {
        guard let running else { return nil }
        let elapsed = max(0, Int(date.timeIntervalSince(running.startedAt)))
        return .init(
            title: "Baseline running on main at \(short(running.commit))"
                + " \u{00B7} started because \(running.trigger.rawValue) from \(short(lastBasedMainCommit))"
                + " \u{00B7} \(duration(elapsed))",
            message: "Catching up agentos/main waits; agents keep working.",
            latestLogLine: running.latestLogLine,
            fullLog: running.fullLog,
            actions: [.stop]
        )
    }

    private func schedule(commit: String, trigger: MainBaselineTrigger) {
        guard !checkedCommits.contains(commit), running?.commit != commit, pending?.commit != commit else { return }
        if running != nil {
            pending = .init(commit: commit, trigger: trigger)
        } else {
            start(.init(commit: commit, trigger: trigger))
        }
    }

    private func start(_ next: Pending) {
        let log = FileManager.default.temporaryDirectory
            .appending(path: "agentos-baseline-\(next.commit).log")
        running = .init(
            commit: next.commit,
            trigger: next.trigger,
            startedAt: now(),
            fullLog: log,
            latestLogLine: nil
        )
        recordedLedgerEvents.append(.baselineStarted(commit: next.commit, trigger: next.trigger))

        let request = MainBaselineRequest(
            commit: next.commit,
            trigger: next.trigger,
            fullLog: log
        ) { [weak self] line in
            await self?.recordLogLine(line, commit: next.commit)
        }
        let runner = runner
        Task {
            let result = await runner(request)
            self.finished(result, commit: next.commit, trigger: next.trigger)
        }
    }

    private func recordLogLine(_ line: String, commit: String) {
        guard running?.commit == commit else { return }
        running?.latestLogLine = line
    }

    private func finished(_ result: BaselineRunResult, commit: String, trigger: MainBaselineTrigger) {
        guard running?.commit == commit else { return }
        if running?.latestLogLine == nil {
            running?.latestLogLine = result.latestLogLine
        }
        recordedLedgerEvents.append(.baselineFinished(commit: commit, passed: result.passed, trigger: trigger))
        checkedCommits.insert(commit)
        running = nil
        if let next = pending {
            pending = nil
            start(next)
        }
    }

    private func short(_ commit: String) -> String {
        String(commit.prefix(8))
    }

    private func duration(_ seconds: Int) -> String {
        String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }
}
