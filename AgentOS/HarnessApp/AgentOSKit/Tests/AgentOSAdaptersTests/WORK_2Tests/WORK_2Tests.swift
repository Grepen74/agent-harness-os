// PolicyPane's baseline section exposes an info-circle tooltip and contextual help on its run button.

import Foundation
import Testing

@Suite
struct WORK_2Tests {
    @Test
    func baselineRowHasAnInformationTooltip() throws {
        let source = try policyPaneBaselineSource()

        #expect(source.contains(#"Image(systemName: "info.circle")"#))
        #expect(matches(#"Button[\s\S]*?Image\(systemName: "info\.circle"\)[\s\S]*?\.help\("#, in: source))
    }

    @Test
    func runBaselineButtonHasATooltip() throws {
        let source = try policyPaneBaselineSource()
        let buttonStart = try #require(source.range(of: #"Button("Run baseline")"#))
        let progressStart = try #require(
            source.range(of: "ProgressView", range: buttonStart.upperBound..<source.endIndex)
        )
        let runButton = source[buttonStart.lowerBound..<progressStart.lowerBound]

        #expect(runButton.contains(".help("))
    }

    private func policyPaneBaselineSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let policyPane = testFile
            .deletingLastPathComponent()
            .appending(path: "../../../Sources/AgentOSUI/PolicyPane.swift")
            .standardizedFileURL
        let source = try String(contentsOf: policyPane, encoding: .utf8)
        let baselineStart = try #require(source.range(of: "@ViewBuilder private var baseline"))
        let baselineEnd = try #require(source.range(of: "private struct SettingRow"))
        return String(source[baselineStart.lowerBound..<baselineEnd.lowerBound])
    }

    private func matches(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: .regularExpression) != nil
    }
}
