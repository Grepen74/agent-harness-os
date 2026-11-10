// API contract: OutputWindowPresentation exposes the resize axes used while presenting Log and Changes windows.

import SwiftUI
import Testing
@testable import AgentOSUI

@Suite
struct GH_17_1Tests {
    @Test
    func logWindowCanResizeHorizontallyAndVertically() {
        let presentation = OutputWindowPresentation.log

        #expect(presentation.resizeAxes.contains(.horizontal))
        #expect(presentation.resizeAxes.contains(.vertical))
    }

    @Test
    func changesWindowCanResizeHorizontallyAndVertically() {
        let presentation = OutputWindowPresentation.changes

        #expect(presentation.resizeAxes.contains(.horizontal))
        #expect(presentation.resizeAxes.contains(.vertical))
    }
}
