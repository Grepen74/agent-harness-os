import Foundation

enum PredictedPath {
    static func normalize(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { original in
            var path = original
            while path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
            while path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty, path != ".", seen.insert(path).inserted else { return nil }
            return path
        }
    }
}
