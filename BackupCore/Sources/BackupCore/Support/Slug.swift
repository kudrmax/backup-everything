import Foundation

public enum Slug {
    public static func make(from name: String, existing: Set<String>) -> String {
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let base = joined.isEmpty ? "source" : joined
        var candidate = base
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// The slug as a folder name inside a destination. A slug edited by hand in `config.json` can be empty or lead
    /// elsewhere (“..”, “a/b”); such a slug is refused, so the destination root or a foreign folder is never touched.
    static func folderName(_ slug: String) throws -> String {
        guard !slug.isEmpty, slug != ".", !slug.contains("/"), !slug.contains("..") else {
            throw DestinationError.invalidFolderName(slug)
        }
        return slug
    }
}
