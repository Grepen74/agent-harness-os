import Foundation

struct BreakdownTestUpdates {
    var files: [String] = []
    var notes: [String] = []

    var description: String { notes.map { "\n   \($0)" }.joined() }
}

extension Reconciler {
    /// Only a preview already visible when the person opened the gate can grant test-update permission.
    func breakdownTestApprover(_ node: NodeState, in state: WorkingState) async -> Participant? {
        guard node.gates.contains(.breakdown),
              let preview = state.previews[node.ticket], preview.specHash == node.spec.specHash else { return nil }
        let records = await ledger.allRecords().filter { $0.position <= state.asOf }
        guard let gate = records.last(where: {
            guard $0.event.node == node.id, case .gateOpened(.breakdown) = $0.event.kind else { return false }
            return true
        }), gate.event.by.isHuman else { return nil }
        guard let shown = records.last(where: {
            guard case .previewRecorded(let ticket, _, _, _) = $0.event.kind else { return false }
            return ticket == node.ticket
        }), shown.position < gate.position,
        case .previewRecorded(_, let number, let hash, let proposal) = shown.event.kind,
        number == preview.number, hash == node.spec.specHash, proposal == preview.proposal else { return nil }
        return gate.event.by
    }

    func breakdownTestUpdates(
        _ children: [NodeSpec], of node: NodeState, approvedBy person: Participant?, in state: WorkingState
    ) async throws -> [NodeID: BreakdownTestUpdates] {
        guard children.contains(where: { !$0.affectedTests.isEmpty }) else { return [:] }
        guard person != nil else {
            return Dictionary(uniqueKeysWithValues: children.map { child in
                (child.id, BreakdownTestUpdates(notes: child.affectedTests.map {
                    "\($0): not approved; no matching preview was approved. Use harness:replan, then harness:preview before approving again."
                }))
            })
        }
        guard let directory = try await workspace.createSnapshot() else {
            return Dictionary(uniqueKeysWithValues: children.map { child in
                (child.id, BreakdownTestUpdates(notes: child.affectedTests.map {
                    "\($0): not approved; no repository snapshot was available to resolve the test. Use harness:replan and harness:preview once it is available."
                }))
            })
        }
        var updates: [NodeID: BreakdownTestUpdates] = [:]
        for child in children {
            var result = BreakdownTestUpdates()
            let target = children.count == 1 ? node.id : child.id
            for test in child.affectedTests {
                // Unlanded tests may only exist on their owner's branch, not in this snapshot.
                let files = declaringFiles(of: test, in: directory, includingMissingPaths: true).sorted()
                if files.isEmpty {
                    result.notes.append("\(test): not approved; no declaring test file was found. Correct the affected tests with harness:replan and harness:preview.")
                }
                for file in files {
                    let owners = state.nodes.values.filter { owner in
                        let folder = workspace.testFolder(for: owner.spec)
                        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
                        return owner.id != target && owner.landedCommit == nil && file.hasPrefix(prefix)
                    }.map(\.ticket).sorted()
                    if !owners.isEmpty {
                        result.notes.append("\(file): not approved; \(owners.joined(separator: ", ")) owns this test and its work is still in progress. Wait for it to land, then use harness:replan and harness:preview.")
                    } else if declaringFiles(of: file, in: directory).isEmpty {
                        result.notes.append("\(file): not approved; no declaring test file was found. Correct the affected tests with harness:replan and harness:preview.")
                    } else if !result.files.contains(file) {
                        result.files.append(file)
                        result.notes.append("\(file): test updates approved for this ticket's test author.")
                    }
                }
            }
            updates[child.id] = result
        }
        await workspace.removeSnapshot(directory)
        return updates
    }
}
