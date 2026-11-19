import AgentOSCore
import SwiftUI

/// The harness's landing batch limit; a repo may choose a smaller batch.
@MainActor
public struct LandingBatchSizeStepper: View {
    @Binding private var settings: HarnessSettings

    public init(settings: Binding<HarnessSettings>) {
        _settings = settings
    }

    public var body: some View {
        Stepper("Landing batch size: \(settings.landingBatchSize)",
                value: $settings.landingBatchSize, in: 1...Int.max)
            .help("Maximum nodes checked together when landing. A repo may lower this; 1 lands one at a time.")
    }
}
