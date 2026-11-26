import Foundation

extension CopilotCLI {
    /// Read the CLI's usage summary, never an estimate derived from tokens or the selected model. Copilot CLI ends a
    /// run with `AI Credits 24.25 (6m 54s)`; older versions printed `Total usage est: 24.25 AI credits`. The last
    /// summary line counts: the agent's own answer above it may quote one.
    static func aiCredits(in output: String) -> Double? {
        var credits: Double?
        for line in output.split(whereSeparator: \.isNewline) {
            if let amount = summaryAmount(in: line) { credits = amount }
        }
        return credits
    }

    private static var summaries: [Regex<(Substring, amount: Substring)>] { [
        #/^[ \t]*AI Credits?[ \t]+(?<amount>[0-9][0-9,]*(?:\.[0-9]+)?)(?:[ \t]+\([^()]*\))?[ \t]*\r?$/#,
        #/^[ \t]*Total usage est:[ \t]*(?<amount>[0-9][0-9,]*(?:\.[0-9]+)?)[ \t]+AI credits?[ \t]*\r?$/#,
    ] }

    private static func summaryAmount(in line: Substring) -> Double? {
        for summary in summaries {
            guard let match = try? summary.wholeMatch(in: line),
                  let amount = Double(match.amount.replacing(",", with: "")), amount.isFinite else { continue }
            return amount
        }
        return nil
    }
}
