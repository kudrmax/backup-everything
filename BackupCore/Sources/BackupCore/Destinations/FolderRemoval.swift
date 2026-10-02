import Darwin
import Foundation

/// Deletes copies and work folders for good or moves work items to the Trash. They keep the locks, permissions and access
/// lists of the originals, so before deleting, every item is unlocked, its access list is dropped and every folder is opened
/// to its owner. Links are never followed.
struct FolderRemoval {
    private let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)

    func remove(_ path: String) throws {
        try unlockTree(path)
        try FileManager.default.removeItem(atPath: path)
    }

    /// Lifts what keeps this one item from being renamed or deleted.
    func unlock(_ path: String) throws {
        _ = try unlockItem(path)
    }

    /// The item goes to the Trash as it is; only when it cannot, it is unlocked whole and moved again.
    func trash(_ url: URL, using trash: ManualExportInbox.Trash) throws {
        do {
            try trash(url)
        } catch {
            try unlockTree(url.path)
            try trash(url)
        }
    }

    private func unlockTree(_ path: String) throws {
        guard try unlockItem(path) == S_IFDIR else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: path) {
            try unlockTree(path + "/" + name)
        }
    }

    /// Returns the item type.
    private func unlockItem(_ path: String) throws -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw currentError() }
        let type = info.st_mode & S_IFMT
        if info.st_flags & lockFlags != 0 && lchflags(path, info.st_flags & ~lockFlags) != 0 { throw currentError() }
        guard type != S_IFLNK else { return type }
        try dropAccessList(path)
        if type == S_IFDIR && info.st_mode & S_IRWXU != S_IRWXU {
            guard chmod(path, (info.st_mode & 0o7777) | S_IRWXU) == 0 else { throw currentError() }
        }
        return type
    }

    private func dropAccessList(_ path: String) throws {
        guard let existing = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return }
        acl_free(UnsafeMutableRawPointer(existing))
        guard let empty = acl_init(0) else { throw currentError() }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        guard acl_set_link_np(path, ACL_TYPE_EXTENDED, empty) == 0 else { throw currentError() }
    }

    private func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
