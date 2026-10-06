import Darwin
import Foundation

/// Copies exactly the listed items of a payload into a folder with Apple's copy engine (`copyfile(3)` with
/// `COPYFILE_RECURSIVE | COPYFILE_ALL`, as Finder and `ditto` copy): names byte for byte, data (APFS compression included),
/// dates, permissions, flags, access lists and extended attributes, folders after their contents. Whatever the listing
/// leaves out (exclusions, companions that hold attributes on a disk without them) is skipped. The engine creates links
/// only after it has sealed their folders (a read-only or locked folder then loses them, and any folder gets a new date),
/// so each link is copied by the same engine just before its folder is sealed. The target folder keeps its own metadata.
/// Every item is created anew (`COPYFILE_EXCL`): whatever is already at a target — a file, a link, a folder, or an item of
/// this copy whose name the destination does not tell apart — stops the copy and is neither written over nor followed.
/// An original that vanished after the payload was listed is left out, as if it had vanished a moment earlier; when the
/// payload itself or a disk mounted inside it is gone (ejected), copying stops with an error that says so. The engine tells
/// which listed items it wrote; the copy is then checked against that by the returned `WrittenCopy`.
struct PayloadCopier {
    private static let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)

    /// `afterEachItem` learns the path of each file and link in the copy right after it is written (tests use it to meddle).
    @discardableResult
    func copy(_ listing: PayloadListing, into base: String, afterEachItem: @escaping (String) -> Void = { _ in }) throws -> WrittenCopy {
        let session = CopySession(listing, base: base, afterEachItem: afterEachItem)
        for entry in listing.entries where !entry.relativePath.contains("/") {
            if entry.kind == .directory {
                session.copyTree(entry)
            } else {
                session.copyAlone(entry)
            }
            if let failure = session.failure { throw failure }
        }
        return WrittenCopy(listing: listing, written: session.written, originalsAfterCopy: session.originalsAfterCopy)
    }

    /// What one copy has learnt so far; the engine's callback reaches it through its context pointer.
    private final class CopySession {
        let listing: PayloadListing
        let base: String
        let afterEachItem: (String) -> Void
        private let root: String
        private let entries: [String: PayloadEntry]
        private let links: [String: [PayloadEntry]]
        private var skippedFolders: Set<String> = []
        /// Listed items the engine wrote into the copy, by relative path.
        private(set) var written: Set<String> = []
        private(set) var originalsAfterCopy: [String: WrittenCopy.OriginalAfterCopy] = [:]
        private(set) var failure: Error?

        init(_ listing: PayloadListing, base: String, afterEachItem: @escaping (String) -> Void) {
            self.listing = listing
            self.base = base
            self.afterEachItem = afterEachItem
            root = listing.origin.path
            entries = Dictionary(listing.entries.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
            links = Dictionary(grouping: listing.entries.filter { $0.kind == .symlink }) { ($0.relativePath as NSString).deletingLastPathComponent }
        }

        /// A folder at the top of the payload with everything in it.
        func copyTree(_ folder: PayloadEntry) {
            guard let state = copyfile_state_alloc() else { return fail(Self.currentError()) }
            defer { copyfile_state_free(state) }
            let callback: copyfile_callback_t = { what, stage, _, source, target, context in
                Unmanaged<CopySession>.fromOpaque(context!).takeUnretainedValue()
                    .handle(what: what, stage: stage, source: source.map { String(cString: $0) }, target: target.map { String(cString: $0) })
            }
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
            copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())
            let target = base + "/" + folder.relativePath
            if copyfile(folder.url.path + "/", target, state, PayloadCopier.flags | copyfile_flags_t(COPYFILE_RECURSIVE)) != 0, failure == nil {
                _ = goesOnWithout(folder, at: target, error: Self.currentError())
            }
        }

        /// A file or link copied by itself: the payload's single file, an item at its top, or a link in a folder that is
        /// not sealed yet.
        func copyAlone(_ entry: PayloadEntry) {
            let target = base + "/" + entry.relativePath
            guard copyfile(entry.url.path, target, nil, PayloadCopier.flags) == 0 else {
                _ = goesOnWithout(entry, at: target, error: Self.currentError())
                return
            }
            written.insert(entry.relativePath)
            if entry.kind == .file { originalsAfterCopy[entry.relativePath] = Self.original(at: entry.url.path) }
            afterEachItem(target)
        }

        private func handle(what: Int32, stage: Int32, source: String?, target: String?) -> Int32 {
            guard let source else { return COPYFILE_CONTINUE }
            let relative = relativePath(of: source)
            let entry = entries[relative]
            switch (what, stage) {
            case (COPYFILE_RECURSE_DIR, COPYFILE_START):
                guard entry?.kind == .directory else {
                    skippedFolders.insert(relative)
                    return COPYFILE_SKIP
                }
                written.insert(relative)
            case (COPYFILE_RECURSE_FILE, COPYFILE_START):
                return entry?.kind == .file ? COPYFILE_CONTINUE : COPYFILE_SKIP
            case (COPYFILE_RECURSE_FILE, COPYFILE_FINISH):
                if entry?.kind == .file {
                    written.insert(relative)
                    originalsAfterCopy[relative] = Self.original(at: source)
                }
                if let target { afterEachItem(target) }
            case (COPYFILE_RECURSE_DIR_CLEANUP, COPYFILE_START):
                if skippedFolders.contains(relative) { return COPYFILE_SKIP }
                for link in links[relative] ?? [] { copyAlone(link) }
                return failure == nil ? COPYFILE_CONTINUE : COPYFILE_QUIT
            case (_, COPYFILE_ERR):
                let error = Self.currentError()
                guard let entry else {
                    fail(error)
                    return COPYFILE_QUIT
                }
                return goesOnWithout(entry, at: target, error: error) ? COPYFILE_SKIP : COPYFILE_QUIT
            default:
                break
            }
            return COPYFILE_CONTINUE
        }

        /// True when the item vanished and copying goes on without it. Something already at its target stops the copy.
        private func goesOnWithout(_ entry: PayloadEntry, at target: String?, error: POSIXError) -> Bool {
            if error.code == .EEXIST, let target {
                fail(DestinationError.collisionInCopy(Self.withoutTrailingSlashes(target)))
                return false
            }
            let loss = error.code == .ENOENT
                ? listing.origin.lossOfMissing(entry.url, wasOn: entry.device)
                : listing.origin.loss(ofListed: entry)
            switch loss {
            case .vanished:
                written.remove(entry.relativePath)
                return true
            case let .gone(loss):
                fail(loss)
            case nil:
                fail(error)
            }
            return false
        }

        private func fail(_ error: Error) {
            if failure == nil { failure = error }
        }

        private func relativePath(of source: String) -> String {
            var path = source.utf8.starts(with: root.utf8) ? String(decoding: source.utf8.dropFirst(root.utf8.count), as: UTF8.self) : source
            while path.hasPrefix("/") { path.removeFirst() }
            return Self.withoutTrailingSlashes(path)
        }

        private static func withoutTrailingSlashes(_ path: String) -> String {
            var path = path
            while path.hasSuffix("/") { path.removeLast() }
            return path
        }

        /// How the original looks right after it was copied; nil when it cannot be looked at.
        private static func original(at path: String) -> WrittenCopy.OriginalAfterCopy? {
            var info = stat()
            guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : nil }
            return .size(Int64(info.st_size))
        }

        private static func currentError() -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
