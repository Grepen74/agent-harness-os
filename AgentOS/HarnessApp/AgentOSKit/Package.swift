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
    // Every target lists every module of this package it imports, even one it also gets through another dependency:
    // the incremental build only recompiles a target when a listed dependency changes, so a type's new layout would
    // otherwise leave stale code that crashes the tests (PackageDependencyTests checks this).
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
        // Helpers every test target may use, e.g. reading what a view shows. Inside the test area, so tickets can't
        // change it.
        .target(name: "AgentOSTestSupport", path: "Tests/AgentOSAdaptersTests/Shared"),
        .testTarget(name: "AgentOSCoreTests", dependencies: ["AgentOSCore"]),
        .testTarget(
            name: "AgentOSAdaptersLegacyTests",
            dependencies: ["AgentOSCore", "AgentOSAdapters", "AgentOSSimulation", "AgentOSUI", "AgentOSTestSupport"],
            path: "Tests/AgentOSAdaptersTests",
            exclude: ["GH_15_1Tests", "GH_29_1Tests", "GH_29_4Tests", "GH_30_4Tests", "GH_68Tests", "Shared"],
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-access-control"])]
        ),
        .testTarget(
            name: "AgentOSAdaptersGH68Tests",
            dependencies: ["AgentOSCore", "AgentOSAdapters", "AgentOSUI", "AgentOSTestSupport"],
            path: "Tests/AgentOSAdaptersTests/GH_68Tests"
        ),
        .testTarget(
            name: "AgentOSAdaptersGH151Tests",
            dependencies: ["AgentOSCore", "AgentOSAdapters", "AgentOSTestSupport"],
            path: "Tests/AgentOSAdaptersTests/GH_15_1Tests",
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-access-control"])]
        ),
        .testTarget(
            name: "AgentOSAdaptersTests",
            dependencies: ["AgentOSCore", "AgentOSAdapters", "AgentOSTestSupport"],
            path: "Tests/AgentOSAdaptersTests/GH_29_1Tests",
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-access-control"])]
        ),
        .testTarget(
            name: "AgentOSAdaptersGH294Tests",
            dependencies: ["AgentOSCore", "AgentOSAdapters", "AgentOSTestSupport"],
            path: "Tests/AgentOSAdaptersTests/GH_29_4Tests",
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-access-control"])]
        ),
        .testTarget(
            name: "AgentOSAdaptersGH304Tests",
            dependencies: ["AgentOSCore", "AgentOSAdapters", "AgentOSTestSupport"],
            path: "Tests/AgentOSAdaptersTests/GH_30_4Tests",
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-access-control"])]
        ),
        .testTarget(name: "AgentOSSimulationTests",
                    dependencies: ["AgentOSCore", "AgentOSAdapters", "AgentOSSimulation", "AgentOSTestSupport"]),
        .testTarget(name: "AgentOSUITests", dependencies: ["AgentOSCore", "AgentOSUI", "AgentOSTestSupport"]),
    ]
)
