import Foundation

struct GlobPattern: Sendable {
    private let pattern: String

    init(_ pattern: String) {
        self.pattern = Self.normalize(pattern)
    }

    func matches(_ text: String) -> Bool {
        fnmatch(pattern, Self.normalize(text), 0) == 0
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }
}
