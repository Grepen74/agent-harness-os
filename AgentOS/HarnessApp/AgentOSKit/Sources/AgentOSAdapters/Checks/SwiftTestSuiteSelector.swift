import Foundation

/// SwiftPM identifiers use `Module.Suite/test()` or `Module.Suite`.
enum SwiftTestSuiteSelector {
    static func pattern(for suite: String) -> String {
        #"\."# + NSRegularExpression.escapedPattern(for: suite) + "(/|$)"
    }

    static func shellArgument(for suite: String) -> String {
        "'" + pattern(for: suite).replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
