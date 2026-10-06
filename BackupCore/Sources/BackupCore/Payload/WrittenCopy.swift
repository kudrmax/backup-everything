import Darwin
import Foundation

/// Checks a finished copy against the listing it was made from: every listed item that did not vanish is in the copy,
/// of the same type, a file as long as its original, a link pointing where its original points. One look at each item:
/// content is not read again. A difference the source explains is no error: an original that changed while it was copied
/// leaves in the copy what was read, and one that vanished is not in the copy.
struct WrittenCopy {
    let listing: PayloadListing

    /// Fails on the first item that is missing from the copy or not as its original. Returns the items that vanished from
    /// the source and are not in the copy.
    @discardableResult
    func check(in base: String) throws -> [PayloadEntry] {
        var vanished: [PayloadEntry] = []
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
            guard try matches(entry, copy, at: path) else { throw DestinationError.changedInCopy(path) }
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
            return Int64(copy.st_size) == entry.size || hasChanged(entry)
        case .symlink:
            return type == S_IFLNK && Self.linkTarget(path) == Self.linkTarget(entry.url.path)
        }
    }

    /// The original is no longer as it was listed: it was written to while it was copied.
    private func hasChanged(_ entry: PayloadEntry) -> Bool {
        var original = stat()
        return lstat(entry.url.path, &original) != 0 || Int64(original.st_size) != entry.size
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
