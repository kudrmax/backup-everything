import Foundation

enum ShellQuoting {
    /// The text as one shell word: single quotes, an embedded quote closed and reopened.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
