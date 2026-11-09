import AppKit
import SwiftUI

/// Shown at launch: open a repo (or a recent one), or the simulator.
struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var recent: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AgentOS Harness").font(.largeTitle.bold())
                Text("Agents take a ticket to a proven change in your repo.").foregroundStyle(.secondary)
            }
            HStack {
                Button { open(AppCommands.chooseRepository()) } label: {
                    Label("Open Repository…", systemImage: "folder")
                }
                .keyboardShortcut(.defaultAction)
                Button {
                    openWindow(id: AgentOSHarnessApp.simulatorID)
                    dismissWindow(id: AgentOSHarnessApp.welcomeID)
                } label: {
                    Label("Show Simulator", systemImage: "play.rectangle")
                }
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent").font(.headline)
                    ForEach(recent, id: \.self) { url in
                        Button { open(url) } label: {
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent)
                                Text(url.path).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .onAppear {
            recent = RecentRepositories.urls
            // `-openRepository <path>` at launch (e.g. in the Xcode scheme's arguments) opens that repo.
            if let path = UserDefaults.standard.string(forKey: "openRepository") {
                open(URL(filePath: path, directoryHint: .isDirectory))
            }
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        openWindow(value: url)
        dismissWindow(id: AgentOSHarnessApp.welcomeID)
    }
}

/// File menu: Open Repository…, the simulator and the welcome window.
struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") {
                if let url = Self.chooseRepository() { openWindow(value: url) }
            }
            .keyboardShortcut("o")
            Button("Show Simulator") { openWindow(id: AgentOSHarnessApp.simulatorID) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Show Welcome Window") { openWindow(id: AgentOSHarnessApp.welcomeID) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }
    }

    @MainActor
    static func chooseRepository() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a git repo. The harness never changes your checkout or its default branch."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// The repos opened lately, newest first, for the welcome window.
enum RecentRepositories {
    private static let key = "recentRepositories"
    private static let limit = 8

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func add(_ url: URL) {
        let paths = [url.path] + (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { $0 != url.path }
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
    }
}
