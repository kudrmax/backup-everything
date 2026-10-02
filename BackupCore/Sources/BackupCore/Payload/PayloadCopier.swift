import Foundation

/// Recreates payload entries in a folder under their exact names. Folders get the dates, permissions and extended attributes
/// of the originals after their contents are in place, deepest first: a read-only folder can still be filled, and filling
/// a folder does not move its date. An original that vanished after the payload was listed is left out, as if it had
/// vanished a moment earlier; when the payload itself or a disk mounted inside it is gone (ejected), copying stops with an error
/// that says so.
struct PayloadCopier {
    private let files = ExactNameFiles()
    private let metadata = FileMetadata()

    /// `placeFile` puts a regular file at the given path. Returns the entries that vanished and are not in the copy.
    @discardableResult
    func copy(_ listing: PayloadListing, into base: String, placeFile: (PayloadEntry, String) throws -> Void) throws -> [PayloadEntry] {
        var vanished: [PayloadEntry] = []
        let unlessVanished = { (entry: PayloadEntry, action: () throws -> Void) throws in
            do {
                try action()
            } catch {
                switch listing.origin.loss(of: entry.url, wasOn: entry.device) {
                case .vanished: vanished.append(entry)
                case let .gone(loss): throw loss
                case nil: throw error
                }
            }
        }
        for entry in listing.entries {
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
        for entry in listing.entries.reversed() where entry.kind == .directory {
            try unlessVanished(entry) { try metadata.apply(from: entry.url.path, to: base + "/" + entry.relativePath) }
        }
        return vanished
    }

    @discardableResult
    func copy(_ listing: PayloadListing, into base: String) throws -> [PayloadEntry] {
        try copy(listing, into: base) { entry, target in try files.copy(entry.url.path, to: target) }
    }
}
