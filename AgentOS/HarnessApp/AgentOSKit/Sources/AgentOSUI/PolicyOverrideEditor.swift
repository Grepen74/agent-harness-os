import AgentOSCore
import AppKit
import Observation

/// The selected, validated fragment shown by PolicyPane and copied on explicit request.
@Observable @MainActor
public final class PolicyOverrideEditor {
    public private(set) var fragment: String?
    private let policy: EffectivePolicy

    public init(policy: EffectivePolicy) {
        self.policy = policy
    }

    public func selectModel(_ identifier: String, for role: AgentOSCore.AgentRole) throws {
        fragment = try policy.modelFragment(for: role, identifier: identifier)
    }

    public func selectSignalsToDisable(_ signals: Set<HarnessCommand>) throws {
        fragment = try policy.signalsFragment(disabling: signals)
    }

    public func copy(to pasteboard: NSPasteboard) throws {
        guard let fragment else { throw CopyError.noSelection }
        pasteboard.clearContents()
        guard pasteboard.setString(fragment, forType: .string) else { throw CopyError.writeFailed }
    }

    private enum CopyError: Error, LocalizedError {
        case noSelection, writeFailed

        var errorDescription: String? {
            switch self {
            case .noSelection: "Choose an override before copying its fragment."
            case .writeFailed: "Couldn't copy the fragment. Try Copy again."
            }
        }
    }
}
