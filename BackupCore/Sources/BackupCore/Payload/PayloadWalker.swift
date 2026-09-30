import Foundation

public struct PayloadWalker: Sendable {
    public init() {}

    public func isDirectory(_ payload: Payload) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: payload.root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func entries(of payload: Payload) throws -> [PayloadEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: payload.root.path) else {
            throw SourceError.pathMissing(payload.root.path)
        }
        guard isDirectory(payload) else {
            let size = (try fileManager.attributesOfItem(atPath: payload.root.path)[.size] as? NSNumber)?.int64Value ?? 0
            return [PayloadEntry(url: payload.root, relativePath: payload.root.lastPathComponent, kind: .file, size: size)]
        }
        guard let enumerator = fileManager.enumerator(atPath: payload.root.path) else {
            throw SourceError.pathMissing(payload.root.path)
        }
        let excludes = payload.excludes.map(GlobPattern.init)
        var entries: [PayloadEntry] = []
        while let relativePath = enumerator.nextObject() as? String {
            let attributes = enumerator.fileAttributes ?? [:]
            let type = attributes[.type] as? FileAttributeType
            let name = (relativePath as NSString).lastPathComponent
            if excludes.contains(where: { $0.matches(relativePath) || $0.matches(name) }) {
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            let kind: PayloadEntry.Kind
            switch type {
            case FileAttributeType.typeDirectory: kind = .directory
            case FileAttributeType.typeSymbolicLink: kind = .symlink
            case FileAttributeType.typeRegular: kind = .file
            default: continue
            }
            entries.append(PayloadEntry(
                url: payload.root.appendingPathComponent(relativePath),
                relativePath: relativePath,
                kind: kind,
                size: kind == .file ? (attributes[.size] as? NSNumber)?.int64Value ?? 0 : 0
            ))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    public func stats(of entries: [PayloadEntry]) -> PayloadStats {
        let files = entries.filter { $0.kind != .directory }
        return PayloadStats(fileCount: files.count, totalBytes: files.reduce(0) { $0 + $1.size })
    }
}
