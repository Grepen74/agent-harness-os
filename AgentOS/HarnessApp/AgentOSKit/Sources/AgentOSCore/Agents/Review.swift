import Foundation

public enum ReviewLevel: String, Codable, Sendable, Equatable, CaseIterable, Comparable {
    case none
    case agent
    case agentAndHuman = "agent+human"

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public struct ReviewerSelection: Codable, Sendable, Equatable {
    public var type: String
    public var model: String?
    public var command: String?

    public init(type: String = "default", model: String? = nil, command: String? = nil) {
        self.type = type
        self.model = model
        self.command = command
    }
}

public struct ReviewSettings: Codable, Sendable, Equatable {
    public var level: ReviewLevel = .agent
    public var reviewer = ReviewerSelection()
    public var offeredModels: [String] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        level = try values.decodeIfPresent(ReviewLevel.self, forKey: .level) ?? .agent
        reviewer = try values.decodeIfPresent(ReviewerSelection.self, forKey: .reviewer) ?? ReviewerSelection()
        offeredModels = try values.decodeIfPresent([String].self, forKey: .offeredModels) ?? []
    }
}

public struct ReviewPolicy: Sendable, Equatable {
    public var level: ReviewLevel = .agent
    public var areas: [String: ReviewLevel] = [:]
    public var instructions: String?
    public var maxRounds = 2
    public var reviewer = ReviewerSelection()
    public var baseBranch = "agentos/main"

    public init() {}

    public var requiresReview: Bool { level != .none || areas.values.contains { $0 != .none } }

    public func level(for areas: [String]) -> ReviewLevel {
        self.areas.reduce(level) { strictest, entry in
            areas.contains(where: {
                $0 == entry.key || $0.hasPrefix(entry.key + "/")
                    || $0.split(separator: "/").contains(Substring(entry.key))
                    || Policy.matches($0, entry.key)
            }) ? max(strictest, entry.value) : strictest
        }
    }
}

public enum ReviewStage: String, Codable, Sendable, Equatable {
    case acceptanceTests, change
}

public struct ReviewResult: Codable, Sendable, Equatable {
    public let passed: Bool
    public let findings: [String]

    public init(passed: Bool, findings: [String]) {
        self.passed = passed
        self.findings = findings
    }
}

public struct UIReviewEvidence: Codable, Sendable, Equatable {
    public var snapshotPaths: [String]
    public var windowsOpened: Bool
    public var windowsClosed: Bool
    public var beforeScreenshot: String?
    public var afterScreenshot: String?

    public init(snapshotPaths: [String], windowsOpened: Bool, windowsClosed: Bool,
                beforeScreenshot: String?, afterScreenshot: String?) {
        self.snapshotPaths = snapshotPaths
        self.windowsOpened = windowsOpened
        self.windowsClosed = windowsClosed
        self.beforeScreenshot = beforeScreenshot
        self.afterScreenshot = afterScreenshot
    }
}

public struct ReviewContext: Sendable {
    public let baseBranch: String
    public let commit: String
    public let fullDiff: String
    public let changedFiles: [String]
    public let recentChanges: [LandedWorkItem]
    public let uiEvidence: UIReviewEvidence?

    public init(baseBranch: String, commit: String, fullDiff: String, changedFiles: [String],
                recentChanges: [LandedWorkItem], uiEvidence: UIReviewEvidence?) {
        self.baseBranch = baseBranch
        self.commit = commit
        self.fullDiff = fullDiff
        self.changedFiles = changedFiles
        self.recentChanges = recentChanges
        self.uiEvidence = uiEvidence
    }
}

public struct ReviewRequest: Sendable {
    public let stage: ReviewStage
    public let spec: NodeSpec
    public let acceptanceTests: [String: String]
    public let context: ReviewContext
    public let instructions: String
    public let directory: URL

    public init(stage: ReviewStage, spec: NodeSpec, acceptanceTests: [String: String],
                context: ReviewContext, instructions: String = "", directory: URL = URL(filePath: ".")) {
        self.stage = stage
        self.spec = spec
        self.acceptanceTests = acceptanceTests
        self.context = context
        self.instructions = instructions
        self.directory = directory
    }
}

public protocol Reviewer: Sendable {
    func review(_ request: ReviewRequest) async throws -> ReviewResult
}

public struct ReviewRecord: Codable, Sendable, Equatable {
    public let stage: ReviewStage
    public let result: ReviewResult
    public let commit: String
    public let uiEvidence: UIReviewEvidence?

    public init(stage: ReviewStage, result: ReviewResult, commit: String, uiEvidence: UIReviewEvidence?) {
        self.stage = stage
        self.result = result
        self.commit = commit
        self.uiEvidence = uiEvidence
    }
}
