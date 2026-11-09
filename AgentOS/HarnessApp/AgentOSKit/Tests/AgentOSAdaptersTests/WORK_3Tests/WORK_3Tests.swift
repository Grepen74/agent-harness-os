// SimulatorToolbar must expose its two control clusters as HStack(spacing: 16) containers.

import Foundation
import Testing

@Suite
struct WORK_3Tests {
    @Test
    func playPauseButtonsHaveIncreasedHorizontalSpacing() throws {
        let groups = try toolbarItemGroups()
        let playbackControls = try #require(groups.first)

        #expect(playbackControls.contains("play.fill"))
        #expect(playbackControls.contains("pause.fill"))
        #expect(playbackControls.contains("HStack(spacing: 16)"))
    }

    @Test
    func userAndFolderControlsHaveIncreasedHorizontalSpacing() throws {
        let groups = try toolbarItemGroups()
        let userAndFolderControls = try #require(groups.dropFirst().first)

        #expect(userAndFolderControls.contains(#"TextField("You""#))
        #expect(userAndFolderControls.contains("Picker("))
        #expect(userAndFolderControls.contains("HStack(spacing: 16)"))
    }

    private func toolbarItemGroups() throws -> [String] {
        let testFile = URL(filePath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = packageRoot
            .deletingLastPathComponent()
            .appending(path: "App/SimulatorView.swift")
        let source = try String(contentsOf: appSource, encoding: .utf8)
        let toolbar = try #require(block(startingWith: "struct SimulatorToolbar:", in: source))

        var groups: [String] = []
        var remainder = toolbar[...]
        while let marker = remainder.range(of: "ToolbarItemGroup") {
            let candidate = remainder[marker.lowerBound...]
            guard let group = block(startingWith: "ToolbarItemGroup", in: String(candidate)) else {
                break
            }
            groups.append(group)
            remainder = candidate.dropFirst(group.count)
        }
        return groups
    }

    private func block(startingWith marker: String, in source: String) -> String? {
        guard let markerRange = source.range(of: marker),
              let openingBrace = source[markerRange.lowerBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        for index in source.indices[openingBrace...] {
            switch source[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[markerRange.lowerBound...index])
                }
            default:
                break
            }
        }
        return nil
    }
}
