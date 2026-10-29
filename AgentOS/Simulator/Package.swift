// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentOSSimulator",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentOSCore", targets: ["AgentOSCore"]),
        .executable(name: "AgentOSSimulator", targets: ["AgentOSSimulator"]),
        .executable(name: "agentos", targets: ["agentos"]),
    ],
    targets: [
        // The harness itself: ledger, reconciler, adapters, agents. No UI.
        .target(name: "AgentOSCore"),
        // Mac app: a read-only view of the ledger plus buttons that send human signals.
        .executableTarget(name: "AgentOSSimulator", dependencies: ["AgentOSCore"]),
        // Headless demo runner.
        .executableTarget(name: "agentos", dependencies: ["AgentOSCore"]),
        .testTarget(name: "AgentOSCoreTests", dependencies: ["AgentOSCore"]),
    ]
)
