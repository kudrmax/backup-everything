import Foundation

/// How much space a destination folder takes. In copies with clones, each piece of a source's content is counted once.
struct DestinationUsage {
    private let fileManager = FileManager.default

    func bytes(under root: URL) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(atPath: root.path) else {
            throw DestinationError.unavailable
        }
        var total: Int64 = 0
        var counted: Set<String> = []
        while let relativePath = enumerator.nextObject() as? String {
            let attributes = enumerator.fileAttributes ?? [:]
            let type = attributes[.type] as? FileAttributeType
            if type == .typeDirectory {
                guard enumerator.level == 2, let manifest = sharedManifest(root.appendingPathComponent(relativePath)) else { continue }
                enumerator.skipDescendants()
                let sourceSlug = (relativePath as NSString).deletingLastPathComponent
                for file in manifest.files ?? [] where counted.insert("\(sourceSlug)/\(file.sha256)").inserted {
                    total += file.size
                }
                total += fileSize(root.appendingPathComponent(relativePath).appendingPathComponent(SnapshotManifest.fileName))
            } else if type == .typeRegular {
                total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    private func sharedManifest(_ directory: URL) -> SnapshotManifest? {
        let url = directory.appendingPathComponent(SnapshotManifest.fileName)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONCoding.decoder().decode(SnapshotManifest.self, from: data),
              manifest.sharesData == true, manifest.files != nil else { return nil }
        return manifest
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
