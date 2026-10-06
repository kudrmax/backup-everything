import Darwin
import Foundation

enum FolderRemovalError: Error, Equatable, LocalizedError {
    case protectedLinkedFile(String)

    var errorDescription: String? {
        switch self {
        case let .protectedLinkedFile(path):
            "“\(path)” is another name (a hard link) of a file elsewhere, and that file is protected from deletion: it is locked or its access list forbids deleting it. It was left as is, so as not to unlock the original. Remove the protection in Finder and retry."
        }
    }
}

/// Deletes copies and work folders for good or moves work items to the Trash. They keep the locks, permissions and access
/// lists of the originals, so before deleting, every item is unlocked, its access list is dropped and every folder is opened
/// to its owner. Links are never followed. A file with other names (hard links, say to a person's file) is never changed:
/// only its name here is removed, which loses nothing. exFAT lists names decomposed (“й” as “и” and a breve) but deletes
/// a name only in the form it was stored in, so a listed item that is not found when deleted is deleted under the other form.
/// Disks without extended attributes of their own delete the “._x” companion together with “x”, so an item inside a folder
/// that is gone by the time it is reached is already deleted.
struct FolderRemoval {
    private enum Item {
        case folder
        case linkedFile
        case other
    }

    private let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)

    func remove(_ path: String) throws {
        try remove(path, isListed: false)
    }

    private func remove(_ path: String, isListed: Bool) throws {
        guard let item = try unlockItem(path, isListed: isListed) else { return }
        switch item {
        case .folder:
            for name in try DirectoryNames.of(path) {
                try remove(path + "/" + name, isListed: true)
            }
            try check(delete(path, with: rmdir))
        case .linkedFile:
            try removeName(path, isListed: isListed)
        case .other:
            try check(delete(path, with: unlink), isListed: isListed)
        }
    }

    /// Lifts what keeps this one item from being renamed or deleted.
    func unlock(_ path: String) throws {
        _ = try unlockItem(path, isListed: false)
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
        switch try unlockItem(path, isListed: false) {
        case .folder:
            for name in try DirectoryNames.of(path) {
                try unlockTree(path + "/" + name)
            }
        case .linkedFile:
            try removeName(path, isListed: false)
        case .other, nil:
            break
        }
    }

    /// Nil for a listed item that is already gone.
    private func unlockItem(_ path: String, isListed: Bool) throws -> Item? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if isListed && errno == ENOENT { return nil }
            throw currentError()
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFREG && info.st_nlink > 1 { return .linkedFile }
        if info.st_flags & lockFlags != 0 && lchflags(path, info.st_flags & ~lockFlags) != 0 { throw currentError() }
        guard type != S_IFLNK else { return .other }
        try dropAccessList(path)
        guard type == S_IFDIR else { return .other }
        if info.st_mode & S_IRWXU != S_IRWXU {
            guard chmod(path, (info.st_mode & 0o7777) | S_IRWXU) == 0 else { throw currentError() }
        }
        return .folder
    }

    private func removeName(_ path: String, isListed: Bool) throws {
        let failure = delete(path, with: unlink)
        if failure == EPERM || failure == EACCES { throw FolderRemovalError.protectedLinkedFile(path) }
        try check(failure, isListed: isListed)
    }

    /// Deletes an item that was just found and returns the error code, 0 on success.
    private func delete(_ path: String, with call: (UnsafePointer<CChar>?) -> Int32) -> Int32 {
        guard call(path) != 0 else { return 0 }
        let failure = errno
        guard failure == ENOENT else { return failure }
        return otherForms(of: path).contains { call($0) == 0 } ? 0 : failure
    }

    /// The path with its last name precomposed and decomposed, when that changes its bytes.
    private func otherForms(of path: String) -> [String] {
        let cut = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        let name = String(path[cut...])
        return [name.precomposedStringWithCanonicalMapping, name.decomposedStringWithCanonicalMapping]
            .filter { !$0.utf8.elementsEqual(name.utf8) }
            .map { String(path[..<cut]) + $0 }
    }

    private func check(_ failure: Int32, isListed: Bool = false) throws {
        guard failure != 0, !(isListed && failure == ENOENT) else { return }
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
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
