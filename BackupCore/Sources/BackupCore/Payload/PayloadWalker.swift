import Darwin
import Foundation

public struct PayloadWalker: Sendable {
    public init() {}

    public func isDirectory(_ payload: Payload) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: payload.root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Everything the payload holds. A symbolic link given as the root stands for what it points to; links inside stay links.
    /// A folder or item that cannot be read is an error: a copy without it would look complete.
    public func entries(of payload: Payload) throws -> [PayloadEntry] {
        try listing(of: payload).entries
    }

    func listing(of payload: Payload) throws -> PayloadListing {
        guard FileManager.default.fileExists(atPath: payload.root.path) else {
            throw SourceError.pathMissing(payload.root.path)
        }
        let root = try isSymbolicLink(payload.root) ? payload.root.resolvingSymlinksInPath() : payload.root
        var origin = try PayloadOrigin(root)
        guard isDirectory(payload) else {
            let attributes = try attributes(of: root)
            let entry = PayloadEntry(url: root, relativePath: payload.root.lastPathComponent, kind: .file, size: size(in: attributes), device: device(in: attributes), inode: inode(in: attributes))
            return PayloadListing(origin: origin, entries: [entry])
        }
        var entries: [PayloadEntry] = []
        try collect(root, prefix: "", filter: Filter(payload), origin: &origin, into: &entries)
        return PayloadListing(origin: origin, entries: entries.sorted { $0.relativePath < $1.relativePath })
    }

    public func stats(of entries: [PayloadEntry]) -> PayloadStats {
        let files = entries.filter { $0.kind != .directory }
        return PayloadStats(fileCount: files.count, totalBytes: files.reduce(0) { $0 + $1.size })
    }

    private struct Filter {
        let anywhere: [GlobPattern]
        let atTop: [GlobPattern]

        init(_ payload: Payload) {
            anywhere = payload.excludes.map(GlobPattern.init)
            atTop = payload.excludedAtTop.map(GlobPattern.init)
        }

        func excludes(_ relativePath: String, name: String) -> Bool {
            anywhere.contains { $0.matches(relativePath) || $0.matches(name) }
                || (relativePath == name && atTop.contains { $0.matches(name) })
        }
    }

    /// Returns false when the folder vanished before it was listed.
    @discardableResult
    private func collect(_ directory: URL, prefix: String, filter: Filter, origin: inout PayloadOrigin, into entries: inout [PayloadEntry]) throws -> Bool {
        guard let names = try names(in: directory, origin: origin) else { return false }
        for name in names {
            let relativePath = prefix.isEmpty ? name : prefix + "/" + name
            guard !filter.excludes(relativePath, name: name),
                  let entry = try entry(at: directory.appendingPathComponent(name), relativePath: relativePath, origin: origin) else { continue }
            guard entry.kind == .directory else {
                entries.append(entry)
                continue
            }
            origin.record(folder: entry.url, device: entry.device)
            var inner: [PayloadEntry] = []
            guard try collect(entry.url, prefix: relativePath, filter: filter, origin: &origin, into: &inner) else { continue }
            entries.append(entry)
            entries += inner
        }
        return true
    }

    /// The names in a folder, without companions that only hold attributes of another item; nil when the folder vanished after its parent was listed (live folders, caches).
    func names(in directory: URL, origin: PayloadOrigin) throws -> [String]? {
        do {
            let names = try DirectoryNames.of(directory.path)
            guard access(directory.path, X_OK) == 0 else { throw POSIXError(.EACCES) }
            return AppleDoubleCompanions.leftOut(of: names, in: directory.path)
        } catch let error as DirectoryNamesError {
            throw error
        } catch {
            return try unlessVanished(directory, origin: origin, error: error)
        }
    }

    /// The item as listed; nil when it vanished after its folder was listed or is neither a file, a folder nor a link.
    func entry(at url: URL, relativePath: String, origin: PayloadOrigin) throws -> PayloadEntry? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try self.attributes(of: url)
        } catch {
            return try unlessVanished(url, origin: origin, error: error)
        }
        let kind: PayloadEntry.Kind
        switch attributes[.type] as? FileAttributeType {
        case FileAttributeType.typeDirectory: kind = .directory
        case FileAttributeType.typeSymbolicLink: kind = .symlink
        case FileAttributeType.typeRegular: kind = .file
        default: return nil
        }
        return PayloadEntry(url: url, relativePath: relativePath, kind: kind, size: kind == .file ? size(in: attributes) : 0, device: device(in: attributes), inode: inode(in: attributes))
    }

    /// Nothing for an item that vanished (was not found when it was read, even if it is back by now); an error when it
    /// cannot be read or its disk is gone.
    private func unlessVanished<Item>(_ url: URL, origin: PayloadOrigin, error: Error) throws -> Item? {
        switch PayloadLoss.isNotFound(error) ? origin.lossOfMissing(url) : origin.loss(of: url) {
        case .vanished: return nil
        case let .gone(error): throw error
        case nil: throw SourceError.unreadable(url.path)
        }
    }

    private func size(in attributes: [FileAttributeKey: Any]) -> Int64 {
        (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func device(in attributes: [FileAttributeKey: Any]) -> dev_t {
        (attributes[.systemNumber] as? NSNumber)?.int32Value ?? 0
    }

    private func inode(in attributes: [FileAttributeKey: Any]) -> ino_t {
        (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        try attributes(of: url)[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func attributes(of url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }
}
