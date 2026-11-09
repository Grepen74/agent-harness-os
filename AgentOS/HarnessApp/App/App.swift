import SwiftUI

/// The app's windows. At launch: the welcome window, plus any repository windows macOS restores.
@main
struct AgentOSHarnessApp: App {
    static let welcomeID = "welcome"
    static let simulatorID = "simulator"
    @State private var settings = SettingsModel()
    @State private var simulator = Simulator()

    var body: some Scene {
        Window("Welcome to AgentOS", id: Self.welcomeID) {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .commands { AppCommands() }

        // One window per repo (File → Open Repository…).
        WindowGroup("Repository", for: URL.self) { $url in
            if let url { RepositoryView(url: url).environment(settings) }
        }

        // Only when asked for (File → Show Simulator).
        Window("AgentOS Simulator", id: Self.simulatorID) {
            SimulatorView()
                .environment(simulator.model)
                .environment(simulator.model.view)
                .frame(minWidth: 1200, minHeight: 700)
        }
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView().environment(settings)
        }
    }
}

/// Creates the simulator the first time its window opens, so working on a repo doesn't start a simulation.
@MainActor
final class Simulator {
    lazy var model = SimulatorModel()
}
