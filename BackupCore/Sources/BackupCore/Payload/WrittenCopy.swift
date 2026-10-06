import Darwin
import Foundation

/// Checks a finished copy against the listing it was made from: every listed item that did not vanish is in the copy,
/// of the same type, a file as long as its original, a link pointing where its original points, and no two listed items
/// are one item of the copy. One look at each item: content is not read again. A difference the source explains is no
/// error: an original that changed while it was copied leaves in the copy what was read, and one that vanished before it
/// was copied is not in the copy. Part of a file whose original vanished while it was copied is not taken for the whole: it
/// is taken out of the copy, so the copy holds what it would hold had the file vanished a moment earlier.
struct WrittenCopy {
    let listing: PayloadListing

    /// Fails on the first item that is missing from the copy or not as its original. Returns the items that vanished from
    /// the source and are not in the copy, including parts of files taken out of it.
    @discardableResult
    func check(in base: String) throws -> [PayloadEntry] {
        var vanished: [PayloadEntry] = []
        var items: Set<Item> = []
        for entry in listing.entries {
            let path = base + "/" + entry.relativePath
            var copy = stat()
            guard lstat(path, &copy) == 0 else {
                guard errno == ENOENT else { throw Self.currentError() }
                switch listing.origin.loss(of: entry.url, wasOn: entry.device) {
                case .vanished:
                    vanished.append(entry)
                    continue
                case let .gone(loss): throw loss
                case nil: throw DestinationError.missingFromCopy(path)
                }
            }
            guard items.insert(Item(device: copy.st_dev, inode: copy.st_ino)).inserted else {
                throw DestinationError.collisionInCopy(path)
            }
            do {
                guard try matches(entry, copy, at: path) else { throw DestinationError.changedInCopy(path) }
            } catch DestinationError.vanishedWhileCopied(let partial) where partial == path {
                do {
                    try FolderRemoval().remove(path)
                } catch {
                    throw DestinationError.vanishedWhileCopied(path)
                }
                vanished.append(entry)
            }
        }
        return vanished
    }

    private func matches(_ entry: PayloadEntry, _ copy: stat, at path: String) throws -> Bool {
        let type = copy.st_mode & S_IFMT
        switch entry.kind {
        case .directory:
            return type == S_IFDIR
        case .file:
            guard type == S_IFREG else { return false }
            return try Int64(copy.st_size) == entry.size || originalChanged(entry, copiedAt: path)
        case .symlink:
            return type == S_IFLNK && Self.linkTarget(path) == Self.linkTarget(entry.url.path)
        }
    }

    /// The original is no longer as it was listed: it was written to while it was copied. An original that cannot be
    /// looked at is not taken for a changed one.
    private func originalChanged(_ entry: PayloadEntry, copiedAt path: String) throws -> Bool {
        var original = stat()
        guard lstat(entry.url.path, &original) == 0 else {
            let error = Self.currentError()
            switch listing.origin.loss(of: entry.url, wasOn: entry.device) {
            case .vanished: throw DestinationError.vanishedWhileCopied(path)
            case let .gone(loss): throw loss
            case nil: throw error
            }
        }
        return Int64(original.st_size) != entry.size
    }

    private struct Item: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    static func linkTarget(_ path: String) -> [CChar]? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(path, &buffer, buffer.count - 1)
        return length < 0 ? nil : Array(buffer.prefix(length))
    }

    private static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
