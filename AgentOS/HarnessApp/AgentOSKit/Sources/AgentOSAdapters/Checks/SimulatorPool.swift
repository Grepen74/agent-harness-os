import AgentOSCore
import Foundation

/// The simulator an `xcodebuild … -destination 'platform=iOS Simulator,name=…,OS=…'` command names.
public struct SimulatorDestination: Hashable, Sendable {
    public var platform: String
    public var name: String
    public var os: String?
    /// The destination as written in the command, without quotes.
    var text: String

    public init?(_ command: String) {
        guard let match = command.firstMatch(of: /-destination\s+(['"])([^'"]*Simulator[^'"]*)\1/) else { return nil }
        text = String(match.output.2)
        var name: String?
        var platform: String?
        for part in text.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            if pair[0] == "platform" { platform = pair[1] }
            if pair[0] == "name" { name = pair[1] }
            if pair[0] == "OS", pair[1] != "latest" { os = pair[1] }
        }
        guard let name else { return nil }
        self.name = name
        self.platform = platform ?? "iOS Simulator"
    }

    /// The same simulator, however the destination is written.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.platform, lhs.name, lhs.os) == (rhs.platform, rhs.name, rhs.os)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(platform)
        hasher.combine(name)
        hasher.combine(os)
    }

    /// The command, run on one specific simulator instead.
    func command(_ command: String, on udid: String) -> String {
        command.replacingOccurrences(of: text, with: "platform=\(platform),id=\(udid)")
    }
}

/// Makes or finds simulators for the harness's own use.
public protocol SimulatorProvider: Sendable {
    /// Up to `count` simulators of the destination's model and OS that belong to the harness; their ids.
    /// Fewer, or none, if they can't be made.
    func devices(like destination: SimulatorDestination, count: Int) async -> [String]
}

/// Simulators for checks that need one, so leaves checked side by side never share a device: each check
/// borrows one and waits while all are in use. Checks that name no simulator don't wait at all.
///
/// The devices are the harness's own copies of the simulator the config names (same model and OS), so your
/// own simulator is left alone. If none can be made, checks use the configured one, one at a time.
public actor SimulatorPool {
    public enum Device: Sendable, Equatable {
        case own(String)
        case asConfigured
    }

    private struct Devices {
        var free: [Device]
        var waiting: [CheckedContinuation<Device, Never>] = []
    }

    public let size: Int
    let provider: any SimulatorProvider
    private var pools: [SimulatorDestination: Devices] = [:]
    private var preparing: [SimulatorDestination: Task<[String], Never>] = [:]

    public init(size: Int, provider: any SimulatorProvider = SimctlProvider()) {
        self.size = max(1, size)
        self.provider = provider
    }

    public func lease(_ destination: SimulatorDestination) async -> Device {
        if pools[destination] == nil {
            let task = preparing[destination] ?? Task { [provider, size] in await provider.devices(like: destination, count: size) }
            preparing[destination] = task
            let ids = await task.value
            if pools[destination] == nil {
                pools[destination] = Devices(free: ids.isEmpty ? [.asConfigured] : ids.map { .own($0) })
            }
        }
        if !pools[destination]!.free.isEmpty { return pools[destination]!.free.removeFirst() }
        return await withCheckedContinuation { pools[destination]!.waiting.append($0) }
    }

    public func release(_ device: Device, of destination: SimulatorDestination) {
        if pools[destination]?.waiting.isEmpty == false {
            pools[destination]!.waiting.removeFirst().resume(returning: device)
        } else {
            pools[destination]?.free.append(device)
        }
    }

    /// Runs `body` with a borrowed simulator: the command to run, rewritten to use it.
    func withSimulator<T: Sendable>(for command: String, _ body: @Sendable (String) async throws -> T) async throws -> T {
        guard let destination = SimulatorDestination(command) else { return try await body(command) }
        let device = await lease(destination)
        let result: Result<T, any Error>
        do {
            if case .own(let udid) = device {
                result = .success(try await body(destination.command(command, on: udid)))
            } else {
                result = .success(try await body(command))
            }
        } catch {
            result = .failure(error)
        }
        release(device, of: destination)
        return try result.get()
    }
}

/// Simulators made with `xcrun simctl create`, named "AgentOS <model> (<OS>) <n>", and reused from then on.
/// Remove them with `xcrun simctl delete <id>` (or in Xcode → Devices and Simulators).
public struct SimctlProvider: SimulatorProvider {
    public init() {}

    struct List: Decodable {
        struct Device: Decodable {
            let name: String
            let udid: String
            let deviceTypeIdentifier: String?
        }
        let devices: [String: [Device]]
    }

    public func devices(like destination: SimulatorDestination, count: Int) async -> [String] {
        guard let listed = try? await xcrun(["simctl", "list", "devices", "available", "-j"]),
              let list = try? JSONDecoder().decode(List.self, from: Data(listed.utf8)),
              let plan = Self.plan(list, like: destination, count: count) else { return [] }
        var ids: [String] = []
        for (name, existing) in plan.devices {
            if let existing {
                ids.append(existing)
            } else if let made = try? await xcrun(["simctl", "create", name, plan.type, plan.runtime]) {
                ids.append(made.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                break
            }
        }
        return ids
    }

    /// The model and runtime to copy (the named simulator on the named OS, else the newest OS that has it),
    /// and the harness's devices by name, with their id if they exist already.
    static func plan(_ list: List, like destination: SimulatorDestination, count: Int)
        -> (type: String, runtime: String, devices: [(name: String, id: String?)])? {
        let sources = list.devices.flatMap { runtime, devices in
            devices.filter { $0.name == destination.name && $0.deviceTypeIdentifier != nil }.map { (runtime: runtime, device: $0) }
        }
        .filter { source in destination.os.map { version(of: source.runtime) == $0 } ?? true }
        .sorted { $0.runtime.compare($1.runtime, options: .numeric) == .orderedDescending }
        guard let source = sources.first, let type = source.device.deviceTypeIdentifier else { return nil }
        let names = (1...max(1, count)).map { "AgentOS \(destination.name) (\(version(of: source.runtime))) \($0)" }
        let devices = names.map { name in (name: name, id: list.devices[source.runtime]?.first { $0.name == name }?.udid) }
        return (type, source.runtime, devices)
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-18-6` → `18.6`.
    static func version(of runtime: String) -> String {
        let id = runtime.split(separator: ".").last.map(String.init) ?? runtime
        return id.split(separator: "-").dropFirst().joined(separator: ".")
    }

    struct Failed: Error {}

    private func xcrun(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/xcrun", arguments, in: FileManager.default.temporaryDirectory,
                                                 timeout: .seconds(120))
        guard result.status == 0 else { throw Failed() }
        return result.output
    }
}
