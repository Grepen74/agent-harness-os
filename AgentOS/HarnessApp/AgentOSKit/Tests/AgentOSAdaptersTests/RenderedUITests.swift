import AgentOSTestSupport
import AppKit
import SwiftUI
import Testing

@MainActor
struct RenderedUITests {
    @Test
    func readsTextAndTheValuesOfControls() throws {
        let text = try RenderedUI.text(of: VStack(alignment: .leading) {
            Text("Independent renderer probe").font(.title)
            Button("Show older") {}
            Picker("Kind", selection: .constant(1)) { Text("All kinds").tag(1) }.fixedSize()
            Toggle("Avoid overlapping work", isOn: .constant(true))
            List { Text("Row inside a list") }.frame(height: 60)
        }.padding(), size: CGSize(width: 700, height: 400))

        for shown in ["Independent renderer probe", "Show older", "All kinds", "Avoid overlapping work", "Row inside a list"] {
            #expect(RenderedUI.shows(shown, in: text), "\(shown) missing from:\n\(text)")
        }
    }

    @Test
    func showsAllowsMisreadLettersButNotOtherDigits() {
        #expect(RenderedUI.shows("Landing batch run-0f0303", in: "#0 • Landing batch run-Of0303: passed"))
        #expect(RenderedUI.shows("Ledger Reviewer", in: "S2 • Ledder Reviewer : GH-69"))
        #expect(!RenderedUI.shows("GH-69", in: "Ticket GH-68"))
        #expect(!RenderedUI.shows("run-0f0303", in: "run-0f0304"))
        #expect(!RenderedUI.shows("Ledgar Reviewar", in: "Ledger Reviewer"), "One misread letter, not two")
        #expect(!RenderedUI.shows("Show older", in: "Show newer"))
        #expect(!RenderedUI.shows("Control-A", in: "half:control-b;"), "A letter after a separator names something else")
        #expect(!RenderedUI.shows("Reviewer A", in: "Reviewer B"))
        #expect(!RenderedUI.shows("Reviewer A done", in: "Reviewer B done"), "Removing spaces doesn't join it to a word")
        #expect(RenderedUI.shows("All kinds", in: "All kibds"), "Next to a letter that folds into a digit")
    }

    @Test
    func readsAKeptViewAgainAfterItChanges() throws {
        let view = NSHostingView(rootView: AnyView(Text("Before the change").font(.title)))
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 120)
        #expect(try RenderedUI.text(in: RenderedUI.image(of: view)).joined().contains("Before the change"))

        view.rootView = AnyView(Text("After the change").font(.title))
        let after = try RenderedUI.text(in: RenderedUI.image(of: view)).joined(separator: "\n")
        #expect(after.contains("After the change") && !after.contains("Before"), "\(after)")
    }
}
