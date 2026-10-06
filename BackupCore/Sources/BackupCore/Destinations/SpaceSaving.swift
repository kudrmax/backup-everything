import Darwin
import Foundation

/// A finished copy of a source in a destination, with its manifest.
struct StoredCopy {
    let directory: URL
    let manifest: SnapshotManifest
}

/// Makes files of a fresh, checked copy share their data with the previous copy of the source (APFS clones). A file is
/// shared only when the previous copy has a file at the same path with the same size and hash, untouched since it was
/// written, and with exactly the same metadata: permissions, owner, flags (compression included), dates, extended
/// attributes and access list. The clone is made beside the file under a temporary name, read in full to check that its
/// hash is the one the manifest gives the file, and renamed over it, so the file is whole at every moment. Anything that
/// fails leaves the full file: saving space never fails a backup, unless a temporary clone cannot be removed and would
/// stay in the copy. Folders keep their dates.
struct SpaceSaving {
    private static let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)

    let cloning: any FileCloning
    private let hash = ContentHash()

    func share(_ files: [SnapshotFile], in directory: URL, with previous: StoredCopy) throws {
        let earlier = Dictionary((previous.manifest.files ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var folderDates: [String: stat] = [:]
        for file in files {
            guard let stored = earlier[file.path], stored.size == file.size, stored.sha256 == file.sha256 else { continue }
            let original = previous.directory.path + "/" + file.path
            let target = directory.path + "/" + file.path
            let folder = (target as NSString).deletingLastPathComponent
            guard isUntouched(original, as: stored), let metadata = Metadata(target), metadata.flags & Self.lockFlags == 0,
                  Metadata(original) == metadata else { continue }
            if folderDates[folder] == nil {
                var info = stat()
                guard lstat(folder, &info) == 0 else { continue }
                folderDates[folder] = info
            }
            try replace(target, withCloneOf: original, as: file)
        }
        for (folder, info) in folderDates {
            var times = [info.st_atimespec, info.st_mtimespec]
            utimensat(AT_FDCWD, folder, &times, AT_SYMLINK_NOFOLLOW)
        }
    }

    private func replace(_ target: String, withCloneOf original: String, as file: SnapshotFile) throws {
        let folder = (target as NSString).deletingLastPathComponent
        let clone = folder + "/.backup-everything-clone-" + UUID().uuidString
        guard (try? cloning.clone(URL(fileURLWithPath: original), to: clone)) != nil, isWhole(clone, as: file), rename(clone, target) == 0 else {
            guard unlink(clone) == 0 || errno == ENOENT else {
                throw DestinationError.leftoverInCopy(clone, reason: String(cString: strerror(errno)) + ".")
            }
            return
        }
    }

    private func isWhole(_ clone: String, as file: SnapshotFile) -> Bool {
        var info = stat()
        guard lstat(clone, &info) == 0, Int64(info.st_size) == file.size else { return false }
        return (try? hash.sha256(of: URL(fileURLWithPath: clone))) == file.sha256
    }

    /// The stored file still has the size and date its manifest gives: nobody changed it by hand.
    private func isUntouched(_ path: String, as stored: SnapshotFile) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == stored.size else { return false }
        return Double(info.st_mtimespec.tv_sec) == stored.modified.timeIntervalSince1970.rounded(.down)
    }

    /// What a person sees of a file besides its data.
    private struct Metadata: Equatable {
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let flags: UInt32
        let modified: [Int]
        let created: [Int]
        let attributes: [String: [UInt8]]
        let accessList: String?

        init?(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0, let attributes = Self.attributes(of: path) else { return nil }
            mode = info.st_mode
            owner = info.st_uid
            group = info.st_gid
            flags = info.st_flags
            modified = [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
            created = [info.st_birthtimespec.tv_sec, info.st_birthtimespec.tv_nsec]
            self.attributes = attributes
            accessList = Self.accessList(of: path)
        }

        private static func attributes(of path: String) -> [String: [UInt8]]? {
            guard let names = read({ listxattr(path, $0, $1, XATTR_NOFOLLOW) }) else { return nil }
            var values: [String: [UInt8]] = [:]
            for name in names.split(separator: 0).map({ String(decoding: $0, as: UTF8.self) }) {
                guard let value = read({ getxattr(path, name, $0, $1, 0, XATTR_NOFOLLOW) }) else { return nil }
                values[name] = value
            }
            return values
        }

        private static func read(_ call: (UnsafeMutablePointer<CChar>?, Int) -> Int) -> [UInt8]? {
            let size = call(nil, 0)
            guard size >= 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let length = buffer.withUnsafeMutableBytes { call($0.baseAddress?.assumingMemoryBound(to: CChar.self), size) }
            return length == size ? buffer : nil
        }

        private static func accessList(of path: String) -> String? {
            guard let list = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
            defer { acl_free(UnsafeMutableRawPointer(list)) }
            guard let text = acl_to_text(list, nil) else { return nil }
            defer { acl_free(UnsafeMutableRawPointer(text)) }
            return String(cString: text)
        }
    }
}
