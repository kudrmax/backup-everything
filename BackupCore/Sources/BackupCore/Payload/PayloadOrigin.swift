import Darwin
import Foundation

/// How an item that cannot be read any more went missing.
enum PayloadLoss: Equatable {
    /// Whether the error says that the item was not found.
    static func isNotFound(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(ENOENT) }
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoSuchFile.rawValue || error.code == CocoaError.fileNoSuchFile.rawValue {
            return true
        }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isNotFound) ?? false
    }

    /// The item is gone while the payload around it is in place: live folders and caches change.
    case vanished
    /// The payload folder is gone or is not the same one (its disk was ejected, it was renamed or replaced), or a disk
    /// mounted inside it was ejected: what is still to be read cannot be, and the copy stops with this error.
    case gone(SourceError)
}

/// The folder (or single file) a payload is read from, as it was when the listing began, and the disk every listed folder
/// was on. Items inside it may vanish while they are read: live folders and caches change. But when the folder itself is
/// gone or is not the same one any more — the disk was ejected, the folder renamed or replaced — or a disk mounted inside
/// it was ejected, nothing vanished: that part can no longer be read, and every item still to be copied would be missing.
struct PayloadOrigin: Sendable {
    let path: String
    private let device: dev_t
    private let inode: ino_t
    private var folders: [String: dev_t] = [:]

    init(_ root: URL) throws {
        var info = stat()
        guard stat(root.path, &info) == 0 else { throw SourceError.pathMissing(root.path) }
        path = root.path
        device = info.st_dev
        inode = info.st_ino
    }

    mutating func record(folder: URL, device: dev_t) {
        folders[folder.path] = device
    }

    /// Why the item is missing; nil when it is not, or when what is wrong with it is not that it is gone. `device` is the
    /// disk the item was on when it was listed; without it, the disk recorded for the item or for its folder is taken.
    func loss(of url: URL, wasOn device: dev_t? = nil) -> PayloadLoss? {
        var info = stat()
        guard lstat(url.path, &info) != 0, errno == ENOENT else { return nil }
        return lossOfMissing(url, wasOn: device)
    }

    /// Why a listed item is no longer there: it is missing, or another item has taken its name (it was deleted and created
    /// anew); nil when it is the listed item itself, or when what is wrong is not that it is gone.
    func loss(ofListed entry: PayloadEntry) -> PayloadLoss? {
        var info = stat()
        if lstat(entry.url.path, &info) == 0 {
            guard info.st_dev == entry.device, entry.inode != 0, info.st_ino != entry.inode else { return nil }
            return lossOfMissing(entry.url, wasOn: entry.device)
        }
        return errno == ENOENT ? lossOfMissing(entry.url, wasOn: entry.device) : nil
    }

    /// Why an item that was found missing (`ENOENT`) is missing. It is not looked at again: an item created anew under the
    /// same name since was still absent when it was looked for. Only whether the payload and its disks are in place is.
    func lossOfMissing(_ url: URL, wasOn device: dev_t? = nil) -> PayloadLoss? {
        var info = stat()
        guard isInPlace else { return .gone(.sourceDisappeared(path)) }
        var folder = (url.path as NSString).deletingLastPathComponent
        while lstat(folder, &info) != 0 {
            guard errno == ENOENT, folder.count > path.count else { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
        guard let itemDevice = device ?? recordedDevice(url.path) ?? recordedDevice((url.path as NSString).deletingLastPathComponent),
              let folderDevice = recordedDevice(folder) else { return nil }
        return info.st_dev == itemDevice && info.st_dev == folderDevice ? .vanished : .gone(.diskDisappeared(folder))
    }

    private func recordedDevice(_ folder: String) -> dev_t? {
        folder == path ? device : folders[folder]
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
