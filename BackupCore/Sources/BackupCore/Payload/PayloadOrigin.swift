import Darwin
import Foundation

/// The folder (or single file) a payload is read from, as it was when the listing began. Items inside it may vanish while
/// they are read: live folders and caches change. But when the folder itself is gone or is not the same one any more —
/// the disk was ejected, the folder renamed or replaced — nothing vanished: the payload can no longer be read, and every
/// item still to be copied would be missing from the copy.
struct PayloadOrigin: Sendable {
    let path: String
    private let device: dev_t
    private let inode: ino_t

    init(_ root: URL) throws {
        var info = stat()
        guard stat(root.path, &info) == 0 else { throw SourceError.pathMissing(root.path) }
        path = root.path
        device = info.st_dev
        inode = info.st_ino
    }

    /// The item is gone, and so may be its folders, while the payload around it is still in place on the same disk.
    func hasVanished(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) != 0, errno == ENOENT, isInPlace else { return false }
        var folder = (url.path as NSString).deletingLastPathComponent
        while lstat(folder, &info) != 0 {
            guard errno == ENOENT, folder.count > path.count else { return false }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return info.st_dev == device
    }

    private var isInPlace: Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_dev == device && info.st_ino == inode
    }
}

/// What a payload holds, listed from its origin.
struct PayloadListing: Sendable {
    let origin: PayloadOrigin
    let entries: [PayloadEntry]
}
