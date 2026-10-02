import Darwin
import Foundation

/// Recreates payload entries in a folder under their exact names. Folders get the dates, permissions and extended attributes
/// of the originals after their contents are in place, deepest first: a read-only folder can still be filled, and filling
/// a folder does not move its date. An original that vanished after the payload was listed is left out, as if it had
/// vanished a moment earlier.
struct PayloadCopier {
    private let files = ExactNameFiles()
    private let metadata = FileMetadata()

    /// `placeFile` puts a regular file at the given path.
    func copy(_ entries: [PayloadEntry], into base: String, placeFile: (PayloadEntry, String) throws -> Void) throws {
        for entry in entries {
            let target = base + "/" + entry.relativePath
            let parent = (entry.relativePath as NSString).deletingLastPathComponent
            switch entry.kind {
            case .directory:
                try files.createDirectories(entry.relativePath, in: base)
            case .symlink:
                try files.createDirectories(parent, in: base)
                try unlessVanished(entry) { try files.copy(entry.url.path, to: target) }
            case .file:
                try files.createDirectories(parent, in: base)
                try unlessVanished(entry) { try placeFile(entry, target) }
            }
        }
        for entry in entries.reversed() where entry.kind == .directory {
            try unlessVanished(entry) { try metadata.apply(from: entry.url.path, to: base + "/" + entry.relativePath) }
        }
    }

    func copy(_ entries: [PayloadEntry], into base: String) throws {
        try copy(entries, into: base) { entry, target in try files.copy(entry.url.path, to: target) }
    }

    private func unlessVanished(_ entry: PayloadEntry, _ action: () throws -> Void) throws {
        do {
            try action()
        } catch {
            var info = stat()
            guard lstat(entry.url.path, &info) != 0, errno == ENOENT else { throw error }
        }
    }
}
