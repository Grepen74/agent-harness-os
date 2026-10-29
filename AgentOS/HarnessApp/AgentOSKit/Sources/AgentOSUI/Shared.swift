import AgentOSCore
import SwiftUI

public struct PaneHeader: View {
    let title: String
    let subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

extension Participant {
    var icon: String {
        switch self {
        case .human: "person.fill"
        case .agent: "cpu"
        case .reconciler: "arrow.triangle.2.circlepath"
        case .adapter: "antenna.radiowaves.left.and.right"
        }
    }
}

extension Phase {
    var color: Color {
        switch self {
        case .specified: .gray
        case .split: .blue
        case .ready: .teal
        case .building: .orange
        case .checking: .purple
        case .landing: .indigo
        case .proven: .green
        }
    }
}
