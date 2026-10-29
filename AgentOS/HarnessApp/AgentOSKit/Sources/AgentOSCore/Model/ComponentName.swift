import Foundation

/// Converts free text into a Swift module name, e.g. "Weather service" → "WeatherService".
public enum ComponentName {
    public static func from(_ text: String, maxWords: Int = 4) -> String {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let name = words.prefix(maxWords).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        guard let first = name.first, first.isLetter else { return "C" + name }
        return name
    }
}
