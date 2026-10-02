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

    private func collect(_ directory: URL, prefix: String, filter: Filter, into entries: inout [PayloadEntry]) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw SourceError.unreadable(directory.path)
        }
        for name in names {
            let relativePath = prefix.isEmpty ? name : prefix + "/" + name
            guard !filter.excludes(relativePath, name: name) else { continue }
            let url = directory.appendingPathComponent(name)
            let attributes = try attributes(of: url)
            let kind: PayloadEntry.Kind
            switch attributes[.type] as? FileAttributeType {
            case FileAttributeType.typeDirectory: kind = .directory
            case FileAttributeType.typeSymbolicLink: kind = .symlink
            case FileAttributeType.typeRegular: kind = .file
            default: continue
            }
            entries.append(PayloadEntry(
                url: url,
                relativePath: relativePath,
                kind: kind,
                size: kind == .file ? (attributes[.size] as? NSNumber)?.int64Value ?? 0 : 0
            ))
            if kind == .directory {
                try collect(url, prefix: relativePath, filter: filter, into: &entries)
            }
        }
    }

    private func isSymbolicLink(_ url: URL) throws -> Bool {
        try attributes(of: url)[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func attributes(of url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }
}
