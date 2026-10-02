import Foundation

public struct Payload: Sendable, Equatable {
    public let root: URL
    /// Glob patterns matched against names and paths at any depth.
    public let excludes: [String]
    /// Names left out only at the top level.
    public let excludedAtTop: [String]
    public let collectedAt: Date
    public let details: String?

    public init(root: URL, excludes: [String] = [], excludedAtTop: [String] = [], collectedAt: Date, details: String? = nil) {
        self.root = root
        self.excludes = excludes
        self.excludedAtTop = excludedAtTop
        self.collectedAt = collectedAt
        self.details = details
    }
}

public struct PayloadEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file
        case directory
        case symlink
    }

    public let url: URL
    public let relativePath: String
    public let kind: Kind
    public let size: Int64
}

public struct PayloadStats: Sendable, Equatable {
    public let fileCount: Int
    public let totalBytes: Int64
}
