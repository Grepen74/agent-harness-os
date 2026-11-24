import Foundation

extension CopilotCLI {
    /// Read the CLI's usage summary, never an estimate derived from tokens or the selected model.
    static func aiCredits(in output: String) -> Double? {
        let pattern = #"(?m)^[ \t]*Total usage est:[ \t]*([0-9]+(?:\.[0-9]+)?)[ \t]+AI credits?[ \t]*\r?$"#
        guard let summary = output.range(of: pattern, options: .regularExpression) else { return nil }
        let fields = output[summary].split(whereSeparator: \.isWhitespace)
        guard fields.count >= 6, let credits = Double(fields[3]), credits.isFinite else { return nil }
        return credits
    }
}
