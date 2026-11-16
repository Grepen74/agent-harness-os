import AgentOSCore
import SwiftUI

/// The harness's overlap protection; repo config may turn it on, but not off.
@MainActor
public struct AvoidOverlappingWorkToggle: View {
    @Binding private var settings: HarnessSettings

    public init(settings: Binding<HarnessSettings>) {
        _settings = settings
    }

    public var body: some View {
        Toggle("Avoid building overlapping work at the same time", isOn: $settings.avoidOverlappingWork)
    }
}
