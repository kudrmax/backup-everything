import Foundation

public struct InboxScan: Sendable, Equatable {
    public var files: [URL]
    public var totalBytes: Int64
    public var downloadInProgress: Bool

    public static let empty = InboxScan(files: [], totalBytes: 0, downloadInProgress: false)

    public init(files: [URL], totalBytes: Int64, downloadInProgress: Bool) {
        self.files = files
        self.totalBytes = totalBytes
        self.downloadInProgress = downloadInProgress
    }

    public var isReady: Bool {
        !files.isEmpty && !downloadInProgress
    }
}

public struct PendingPackage: Sendable, Equatable {
    public let directory: URL
    public let collectedAt: Date
}

public struct ManualExportInbox: Sendable {
    public typealias Trash = @Sendable (URL) throws -> Void

    public static let settleSeconds: TimeInterval = 5
    private static let inProgressExtensions: Set<String> = ["crdownload", "download", "part", "tmp"]

    private let pendingRoot: URL
    private let naming: SnapshotNaming
    private let trash: Trash

    public init(
        pendingRoot: URL,
        naming: SnapshotNaming,
        trash: @escaping Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.pendingRoot = pendingRoot
        self.naming = naming
        self.trash = trash
    }

    public func scan(watchPath: String, filePattern: String, since: Date, now: Date) -> InboxScan {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: Paths.url(watchPath),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        let pattern = GlobPattern(filePattern)
        var scan = InboxScan.empty
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if Self.inProgressExtensions.contains(url.pathExtension.lowercased()) {
                scan.downloadInProgress = true
                continue
            }
            guard pattern.matches(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 0,
                  let modified = values.contentModificationDate else { continue }
            guard max(modified, values.creationDate ?? modified) > since else { continue }
            if now.timeIntervalSince(modified) < Self.settleSeconds {
                scan.downloadInProgress = true
                continue
            }
            scan.files.append(url)
            scan.totalBytes += Int64(size)
        }
        return scan
    }

    public func pickUp(sourceId: UUID, files: [URL], removeOriginal: Bool, at date: Date) throws -> PendingPackage {
        let fileManager = FileManager.default
        let incoming = pendingRoot.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        let directory = sourceDirectory(sourceId).appendingPathComponent(naming.name(for: date), isDirectory: true)
        var moved: [(original: URL, staged: URL)] = []
        do {
            try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
            for file in files {
                let staged = incoming.appendingPathComponent(file.lastPathComponent)
                if removeOriginal {
                    try fileManager.moveItem(at: file, to: staged)
                    moved.append((file, staged))
                } else {
                    try fileManager.copyItem(at: file, to: staged)
                }
            }
        } catch {
            for item in moved.reversed() {
                try? fileManager.moveItem(at: item.staged, to: item.original)
            }
            try? fileManager.removeItem(at: incoming)
            throw error
        }
        try removePackage(for: sourceId, toTrash: removeOriginal)
        try fileManager.createDirectory(at: sourceDirectory(sourceId), withIntermediateDirectories: true)
        try fileManager.moveItem(at: incoming, to: directory)
        return PendingPackage(directory: directory, collectedAt: naming.date(from: directory.lastPathComponent) ?? date)
    }

    public func adopt(sourceId: UUID, directory: URL, at date: Date) throws -> PendingPackage {
        let fileManager = FileManager.default
        try removePackage(for: sourceId, toTrash: true)
        try fileManager.createDirectory(at: sourceDirectory(sourceId), withIntermediateDirectories: true)
        let target = sourceDirectory(sourceId).appendingPathComponent(naming.name(for: date), isDirectory: true)
        try fileManager.moveItem(at: directory, to: target)
        return PendingPackage(directory: target, collectedAt: naming.date(from: target.lastPathComponent) ?? date)
    }

    public func pendingPackage(for sourceId: UUID) -> PendingPackage? {
        let directory = sourceDirectory(sourceId)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .compactMap { name in
                naming.date(from: name).map {
                    PendingPackage(directory: directory.appendingPathComponent(name, isDirectory: true), collectedAt: $0)
                }
            }
            .max { $0.collectedAt < $1.collectedAt }
    }

    public func removePackage(for sourceId: UUID, toTrash: Bool) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceDirectory(sourceId).path) else { return }
        if toTrash, let package = pendingPackage(for: sourceId) {
            for file in try fileManager.contentsOfDirectory(at: package.directory, includingPropertiesForKeys: nil) {
                try trash(file)
            }
        }
        try fileManager.removeItem(at: sourceDirectory(sourceId))
    }

    private func sourceDirectory(_ sourceId: UUID) -> URL {
        pendingRoot.appendingPathComponent(sourceId.uuidString, isDirectory: true)
    }
}
