import AgentOSCore
import SwiftUI

@MainActor
public struct PushPullRequestsToggle: View {
    @Binding private var settings: HarnessSettings

    public init(settings: Binding<HarnessSettings>) {
        _settings = settings
    }

    public var body: some View {
        Toggle("Push / open pull requests", isOn: $settings.pullRequests)
    }
}
