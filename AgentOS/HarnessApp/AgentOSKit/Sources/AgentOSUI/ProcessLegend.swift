import SwiftUI

/// "How to read this" for the Process view: a compact key, open by default, with the glossary collapsed.
struct ProcessLegend: View {
    /// The effective landing batch size (1 when the policy lands one at a time), so the glossary names the real limit.
    let batchSize: Int
    @AppStorage("processLegendExpanded") private var expanded = true
    @State private var glossaryExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    row("Requirement", "A ticket too big to build in one go. It is split into child tickets and waits "
                        + "until their work is proven. Only a top-level requirement then gets a final check of its "
                        + "branch, and a pull request when publishing is on.")
                    row("Leaf", "A ticket small enough to build directly: tests first, then the code, then it "
                        + "lands on the top-level requirement's branch. A small top-level ticket follows the Leaf lane, then "
                        + "the requirement's final steps.")
                    row("Recovery", "Side paths when something goes wrong. Its arrows show when you select a "
                        + "connected stage, or a recovery transition from a stage's outgoing menu.")
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        LineSample(dashed: false)
                        Text("A ticket moves to the next stage.")
                    }
                    GridRow {
                        LineSample(dashed: true)
                        Text("A requirement starts its child tickets, or a proven child reports back. "
                            + "Nothing moves along it.")
                    }
                    GridRow {
                        HStack(spacing: 4) {
                            Capsule().fill(Color.orange).frame(width: 4, height: 14)
                            Image(systemName: "person.fill").foregroundStyle(.orange)
                        }
                        Text("A person may need to act. harness:go on a requirement allows breakdown and build for "
                            + "everything below it; questions, landing approval and merging still need a person.")
                    }
                    GridRow {
                        RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 2)
                            .frame(width: 28, height: 14)
                        Text("The stage you clicked.")
                    }
                    GridRow {
                        Image(systemName: "location.fill").foregroundStyle(.teal)
                        Text("Where the node selected in Work is (dashed border).")
                    }
                }
                DisclosureGroup("Words used here", isExpanded: $glossaryExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repository checks: the repository's prepare and build commands, its test command "
                            + "and the extra checks in .agentos/config.json.")
                        Text("Lands: the requirement branch moves forward to include the change.")
                        Text(batchSize > 1
                            ? "Batch: up to \(batchSize) waiting leaves of one requirement branch, checked together."
                            : "Batch: off under this policy (batch size 1, or changes need a person's review), so "
                                + "changes land one at a time.")
                        Text("Proven: a leaf has landed on the top-level requirement's branch; a requirement has every child "
                            + "proven but is not merged into main yet.")
                    }
                    .padding(.top, 4)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        } label: {
            Text("How to read this").font(.headline)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ lane: String, _ meaning: String) -> some View {
        GridRow {
            Text(lane).bold()
            Text(meaning)
        }
    }
}

/// A short connector drawn like the diagram's own: solid for a transition, dashed for a parent–child link.
private struct LineSample: View {
    let dashed: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
            context.stroke(path, with: .color(.secondary),
                           style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
            var arrow = Path()
            arrow.addLines([CGPoint(x: size.width - 7, y: size.height / 2 - 4),
                            CGPoint(x: size.width - 2, y: size.height / 2),
                            CGPoint(x: size.width - 7, y: size.height / 2 + 4)])
            context.stroke(arrow, with: .color(.secondary), lineWidth: 1)
        }
        .frame(width: 28, height: 14)
        .accessibilityLabel(dashed ? "Dashed line" : "Solid line")
    }
}
