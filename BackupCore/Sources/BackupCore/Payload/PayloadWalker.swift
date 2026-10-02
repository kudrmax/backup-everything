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
        guard FileManager.default.fileExists(atPath: payload.root.path) else {
            throw SourceError.pathMissing(payload.root.path)
        }
        let root = try isSymbolicLink(payload.root) ? payload.root.resolvingSymlinksInPath() : payload.root
        guard isDirectory(payload) else {
            let size = (try attributes(of: root)[.size] as? NSNumber)?.int64Value ?? 0
            return [PayloadEntry(url: root, relativePath: payload.root.lastPathComponent, kind: .file, size: size)]
        }
        var entries: [PayloadEntry] = []
        try collect(root, prefix: "", filter: Filter(payload), into: &entries)
        return entries.sorted { $0.relativePath < $1.relativePath }
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
    private func collect(_ directory: URL, prefix: String, filter: Filter, into entries: inout [PayloadEntry]) throws -> Bool {
        guard let names = try names(in: directory) else { return false }
        for name in names {
            let relativePath = prefix.isEmpty ? name : prefix + "/" + name
            guard !filter.excludes(relativePath, name: name),
                  let entry = try entry(at: directory.appendingPathComponent(name), relativePath: relativePath) else { continue }
            guard entry.kind == .directory else {
                entries.append(entry)
                continue
            }
            var inner: [PayloadEntry] = []
            guard try collect(entry.url, prefix: relativePath, filter: filter, into: &inner) else { continue }
            entries.append(entry)
            entries += inner
        }
        return true
    }

    /// The names in a folder; nil when the folder vanished after its parent was listed (live folders, caches).
    func names(in directory: URL) throws -> [String]? {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            if hasVanished(directory) { return nil }
            throw SourceError.unreadable(directory.path)
        }
    }

    /// The item as listed; nil when it vanished after its folder was listed or is neither a file, a folder nor a link.
    func entry(at url: URL, relativePath: String) throws -> PayloadEntry? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try self.attributes(of: url)
        } catch {
            if hasVanished(url) { return nil }
            throw SourceError.unreadable(url.path)
        }
        let kind: PayloadEntry.Kind
        switch attributes[.type] as? FileAttributeType {
        case FileAttributeType.typeDirectory: kind = .directory
        case FileAttributeType.typeSymbolicLink: kind = .symlink
        case FileAttributeType.typeRegular: kind = .file
        default: return nil
        }
        let size = kind == .file ? (attributes[.size] as? NSNumber)?.int64Value ?? 0 : 0
        return PayloadEntry(url: url, relativePath: relativePath, kind: kind, size: size)
    }

    private func hasVanished(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        try attributes(of: url)[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func attributes(of url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }
}
