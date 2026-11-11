import AgentOSCore
import Foundation

public struct MainMovedReworkContext: Sendable, Equatable {
    public let failureOutput: String
    public let oldMainCommit: String
    public let newMainCommit: String
    public let landedWork: [LandedWorkItem]

    public var mainCommitRange: String {
        "\(oldMainCommit)..\(newMainCommit)"
    }

    public var message: String {
        var lines = [
            "The landing check failed after main moved across \(mainCommitRange).",
            "",
            "Landing failure:",
            failureOutput,
        ]
        if !landedWork.isEmpty {
            lines += ["", "Work landed in that range:"]
            lines += landedWork.map {
                "\($0.ticket) \($0.title) (\($0.commit.prefix(8)))"
            }
        }
        return lines.joined(separator: "\n")
    }

    public init(
        failureOutput: String,
        oldMainCommit: String,
        newMainCommit: String,
        landedWork: [LandedWorkItem]
    ) {
        self.failureOutput = failureOutput
        self.oldMainCommit = oldMainCommit
        self.newMainCommit = newMainCommit
        self.landedWork = landedWork
    }
}

public protocol MainMovementReworkActions: Sendable {
    func resetImplementation(for node: NodeID, onto mainCommit: String) async throws
    func dispatchRework(for node: NodeID, context: MainMovedReworkContext) async throws
    func comment(on ticket: String, text: String) async
    func appendToLedger(_ event: LedgerEvent) async throws
}

public actor MainMovementReworkCoordinator {
    private let actions: any MainMovementReworkActions
    private var latestPassingMain: [NodeID: String] = [:]
    private var consumedMovements: [NodeID: String] = [:]

    public init(actions: any MainMovementReworkActions) {
        self.actions = actions
    }

    public func recordPassingCheck(
        node: NodeID,
        kind: PassingCheckKind,
        mainCommit: String
    ) async throws {
        try await actions.appendToLedger(
            LedgerEvent(
                node: node,
                by: .reconciler,
                kind: .passingCheckRecorded(kind: kind, mainCommit: mainCommit)
            )
        )
        latestPassingMain[node] = mainCommit
        consumedMovements[node] = nil
    }

    public func handleLandingFailure(
        node: NodeID,
        ticket: String,
        output: String,
        currentMainCommit: String,
        landedWork: [LandedWorkItem]
    ) async throws {
        guard let oldMainCommit = latestPassingMain[node],
              oldMainCommit != currentMainCommit,
              consumedMovements[node] != currentMainCommit
        else {
            try await actions.appendToLedger(
                LedgerEvent(node: node, by: .reconciler, kind: .attemptFailed(summary: output))
            )
            return
        }

        let context = MainMovedReworkContext(
            failureOutput: output,
            oldMainCommit: oldMainCommit,
            newMainCommit: currentMainCommit,
            landedWork: landedWork
        )
        try await actions.resetImplementation(for: node, onto: currentMainCommit)
        try await actions.dispatchRework(for: node, context: context)
        await actions.comment(
            on: ticket,
            text: "Landing check failed because main moved from \(oldMainCommit) to \(currentMainCommit).\n"
                + context.message
        )
        try await actions.appendToLedger(
            LedgerEvent(
                node: node,
                by: .reconciler,
                kind: .mainMovedRework(
                    oldMainCommit: oldMainCommit,
                    newMainCommit: currentMainCommit,
                    landedWork: landedWork
                )
            )
        )
        consumedMovements[node] = currentMainCommit
    }
}
