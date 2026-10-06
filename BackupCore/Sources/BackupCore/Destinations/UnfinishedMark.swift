import Darwin
import Foundation

/// The open mark `_unfinished` of a copy folder, locked while its copy is written: another write of the same source (a
/// second running instance) never takes such a folder for an abandoned attempt. The lock is the file system's and goes away
/// with the process, so the mark of a crashed write can be claimed at once.
final class UnfinishedMark {
    let path: String
    private let descriptor: Int32

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Puts a new mark naming the source into the folder, locked from the moment it exists.
    static func create(in folder: URL, sourceId: UUID) throws -> UnfinishedMark {
        let path = folder.appendingPathComponent(SnapshotManifest.unfinishedMarker).path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_EXLOCK | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw currentError() }
        let mark = UnfinishedMark(path: path, descriptor: descriptor)
        let note = Array(SnapshotManifest.unfinishedNote(sourceId: sourceId).utf8)
        guard write(descriptor, note, note.count) == note.count else { throw currentError() }
        return mark
    }

    /// The mark of an unfinished folder, locked for removing the folder; nil while its copy is being written.
    static func claim(in folder: URL) throws -> UnfinishedMark? {
        let path = folder.appendingPathComponent(SnapshotManifest.unfinishedMarker).path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw currentError()
        }
        return UnfinishedMark(path: path, descriptor: descriptor)
    }

    private static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
