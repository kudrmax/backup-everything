import Foundation

/// An exclusion as rsync reads it: case-sensitive, no normalisation. Without a slash it matches the name at any depth; with
/// one, the end of the relative path on component boundaries; a leading slash anchors it at the top. A trailing slash is
/// ignored. `*` does not cross `/`, `**` does.
struct ExcludePattern: Sendable {
    private let pattern: String
    private let anchored: Bool
    private let wholePath: Bool

    init(_ raw: String) {
        var text = Substring(raw)
        if text.hasSuffix("/") { text = text.dropLast() }
        anchored = text.hasPrefix("/")
        if anchored { text = text.dropFirst() }
        pattern = String(text)
        wholePath = anchored || pattern.contains("/")
    }

    func matches(_ relativePath: String, name: String) -> Bool {
        guard wholePath else { return Self.fnmatches(pattern, name) }
        if anchored { return Self.fnmatches(pattern, relativePath) }
        if Self.fnmatches(pattern, relativePath) { return true }
        var index = relativePath.startIndex
        while let slash = relativePath[index...].firstIndex(of: "/") {
            index = relativePath.index(after: slash)
            if Self.fnmatches(pattern, String(relativePath[index...])) { return true }
        }
        return false
    }

    /// `*`, `?` and `[…]` stay inside one name; a pattern with `**` may cross folders, as in rsync.
    private static func fnmatches(_ pattern: String, _ text: String) -> Bool {
        guard pattern.contains("**") else { return fnmatch(pattern, text, FNM_PATHNAME) == 0 }
        let single = pattern.replacingOccurrences(of: "**", with: "*")
        return fnmatch(single, text, FNM_PATHNAME) == 0 || fnmatch(single, text, 0) == 0
    }
}
