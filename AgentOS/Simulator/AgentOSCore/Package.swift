// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentOSSimulator",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentOSCore", targets: ["AgentOSCore"]),
        .executable(name: "agentos", targets: ["agentos"]),
    ],
    targets: [
        // The harness itself: ledger, reconciler, adapters, agents. No UI.
        // The Mac app is a regular Xcode target (../AgentOSSimulator.xcodeproj) that imports this library.
        .target(name: "AgentOSCore"),
        // Headless demo runner.
        .executableTarget(name: "agentos", dependencies: ["AgentOSCore"]),
        .testTarget(name: "AgentOSCoreTests", dependencies: ["AgentOSCore"]),
    ]
)
