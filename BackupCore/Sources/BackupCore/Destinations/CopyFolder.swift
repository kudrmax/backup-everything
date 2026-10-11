import Foundation

/// The copies of sources inside a destination root, read from the folders themselves: a copy is a folder named by its
/// date that holds the completion marker; a dated folder without it is an unfinished copy.
public struct CopyFolder: Sendable {
    public static let completionMarker = ".complete"

    public let root: URL
    private let naming: SnapshotNaming

    public init(root: URL, naming: SnapshotNaming) {
        self.root = root
        self.naming = naming
    }

    public func copies(of slug: String) throws -> [Snapshot] {
        try datedFolders(of: slug).filter { isComplete($0.url) }.map(\.snapshot)
    }

    public func unfinished(of slug: String) throws -> [Snapshot] {
        try datedFolders(of: slug).filter { !isComplete($0.url) }.map(\.snapshot)
    }

    public func newestCopy(of slug: String) throws -> Snapshot? {
        try copies(of: slug).last
    }

    public func url(of snapshot: Snapshot, slug: String) throws -> URL {
        try sourceFolder(slug).appendingPathComponent(snapshot.name, isDirectory: true)
    }

    public func sourceFolder(_ slug: String) throws -> URL {
        root.appendingPathComponent(try Slug.folderName(slug), isDirectory: true)
    }

    private func isComplete(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.completionMarker).path)
    }

    private func datedFolders(of slug: String) throws -> [(url: URL, snapshot: Snapshot)] {
        let folder = try sourceFolder(slug)
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        return items
            .compactMap { url -> (URL, Snapshot)? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let snapshot = naming.snapshot(named: url.lastPathComponent) else { return nil }
                return (url, snapshot)
            }
            .sorted { $0.1.date < $1.1.date }
    }
}
