import Darwin
import Foundation

/// Checks a finished copy against the listing it was made from and against what the copy engine reported while copying:
/// every listed item the engine wrote is in the copy, of the same type, a file as long as its original, a link pointing where
/// its original points, and no two listed items are one item of the copy. One look at each item: content is not read again.
/// A listed item the engine did not write was not there when the engine reached it (it vanished, or another kind of item
/// took its name): it is legitimately absent from the copy even if its original is back by now, as live folders delete and
/// recreate files under the same names (database journals, lock files). Only when the source itself or a disk inside it is
/// gone is that an error. A difference the source explains is no error: an original that changed while it was copied
/// leaves in the copy what was read. Part of a file whose original vanished while it was copied is not taken for the whole:
/// it is taken out of the copy, so the copy holds what it would hold had the file vanished a moment earlier.
struct WrittenCopy {
    /// How the original of a file looked right after the engine copied it.
    enum OriginalAfterCopy: Equatable {
        case absent
        case size(Int64)
    }

    let listing: PayloadListing
    /// Relative paths of the listed items the copy engine wrote.
    let written: Set<String>
    /// The originals of written files as seen right after each was copied, by relative path.
    let originalsAfterCopy: [String: OriginalAfterCopy]

    init(listing: PayloadListing, written: Set<String>, originalsAfterCopy: [String: OriginalAfterCopy] = [:]) {
        self.listing = listing
        self.written = written
        self.originalsAfterCopy = originalsAfterCopy
    }

    /// Fails on the first item that is missing from the copy or not as its original. Returns the listed items that are not
    /// in the copy because their originals were absent when the engine reached them, including parts of files taken out of it.
    @discardableResult
    func check(in base: String) throws -> [PayloadEntry] {
        var vanished: [PayloadEntry] = []
        var items: Set<Item> = []
        for entry in listing.entries {
            let path = base + "/" + entry.relativePath
            var copy = stat()
            guard lstat(path, &copy) == 0 else {
                guard errno == ENOENT else { throw Self.currentError() }
                guard !written.contains(entry.relativePath) else { throw DestinationError.missingFromCopy(path) }
                if case let .gone(loss) = listing.origin.loss(of: entry.url, wasOn: entry.device) { throw loss }
                vanished.append(entry)
                continue
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

    /// The original is no longer as it was listed: it was written to, or deleted and created anew, while it was copied. What was seen right after copying
    /// comes first, so an original deleted and recreated since is not compared again; only when that shows no change is the
    /// original looked at now. An original that cannot be looked at is not taken for a changed one.
    private func originalChanged(_ entry: PayloadEntry, copiedAt path: String) throws -> Bool {
        switch originalsAfterCopy[entry.relativePath] {
        case let .size(size)? where size != entry.size:
            return true
        case .absent?:
            if case let .gone(loss) = listing.origin.loss(of: entry.url, wasOn: entry.device) { throw loss }
            throw DestinationError.vanishedWhileCopied(path)
        default:
            break
        }
        var original = stat()
        guard lstat(entry.url.path, &original) == 0 else {
            let error = Self.currentError()
            let loss = error.code == .ENOENT
                ? listing.origin.lossOfMissing(entry.url, wasOn: entry.device)
                : listing.origin.loss(of: entry.url, wasOn: entry.device)
            switch loss {
            case .vanished: throw DestinationError.vanishedWhileCopied(path)
            case let .gone(loss): throw loss
            case nil: throw error
            }
        }
        return Int64(original.st_size) != entry.size || (entry.inode != 0 && original.st_ino != entry.inode)
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
