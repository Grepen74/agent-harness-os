import SwiftUI

public enum RepositoryInspectorTab: String, CaseIterable, Identifiable {
    case readiness = "Readiness", policy = "Policy", ledger = "Ledger", process = "Process"
    public var id: String { rawValue }
}

/// The real repository's shared inspector; switching tabs is UI-only.
public struct RepositoryInspectorPane: View {
    @Binding private var selection: RepositoryInspectorTab

    public init(selection: Binding<RepositoryInspectorTab>) {
        _selection = selection
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(RepositoryInspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            switch selection {
            case .readiness: FindingsPane()
            case .policy: PolicyPane()
            case .ledger: LedgerPane()
            case .process: ProcessPane()
            }
        }
    }
}
