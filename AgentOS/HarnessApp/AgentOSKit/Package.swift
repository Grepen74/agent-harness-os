// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentOSKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentOSCore", targets: ["AgentOSCore"]),
        .library(name: "AgentOSAdapters", targets: ["AgentOSAdapters"]),
        .library(name: "AgentOSSimulation", targets: ["AgentOSSimulation"]),
        .library(name: "AgentOSUI", targets: ["AgentOSUI"]),
        .executable(name: "agentos", targets: ["agentos"]),
    ],
    targets: [
        // The harness: model, ledger, reconciler, policy, and the protocols for everything outside it
        // (tracker, workspace, checks, agents, stores). No UI, no files, no processes.
        .target(name: "AgentOSCore"),
        // Real-world adapters: file stores, local tracker, SwiftPM check runner, Copilot CLI agents.
        .target(name: "AgentOSAdapters", dependencies: ["AgentOSCore"]),
        // The simulated world: generated monorepo, mock external system, scripted agents, demo content.
        .target(name: "AgentOSSimulation", dependencies: ["AgentOSCore", "AgentOSAdapters"]),
        // SwiftUI panes shared by every kind of window: tracker, work tree, ledger.
        .target(name: "AgentOSUI", dependencies: ["AgentOSCore"]),
        // Headless demo runner.
        .executableTarget(name: "agentos", dependencies: ["AgentOSCore", "AgentOSAdapters", "AgentOSSimulation"]),
        .testTarget(name: "AgentOSCoreTests", dependencies: ["AgentOSCore"]),
        .testTarget(name: "AgentOSAdaptersTests", dependencies: ["AgentOSAdapters"]),
        .testTarget(name: "AgentOSSimulationTests", dependencies: ["AgentOSSimulation"]),
    ]
)
