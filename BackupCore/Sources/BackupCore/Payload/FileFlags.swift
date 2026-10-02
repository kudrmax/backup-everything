import Darwin
import Foundation

/// Changes the flags a person can set (`UF_SETTABLE`: Finder lock, hidden, nodump…) on one item and keeps the rest as the
/// item has them: flags only the system may change (`SF_ARCHIVED` on SMB shares and NAS disks) make the file system refuse
/// any change that touches them. A file system that keeps only some of the flags refuses the whole set: then each flag it
/// keeps is set on its own.
struct FileFlags {
    private static let settable = UInt32(UF_SETTABLE)

    let current: UInt32
    /// Gives the item these flags; returns 0 or the error code.
    let change: (UInt32) -> Int32

    func set(_ wanted: UInt32) throws {
        let flags = (wanted & Self.settable) | (current & ~Self.settable)
        guard flags != current else { return }
        let failure = change(flags)
        guard failure != 0 else { return }
        guard Self.isUnsupported(failure) else { throw Self.error(failure) }
        var applied = current & flags
        for bit in (0..<32).map({ UInt32(1) << $0 }) where flags & ~applied & bit != 0 {
            let failure = change(applied | bit)
            if failure == 0 {
                applied |= bit
            } else if !Self.isUnsupported(failure) {
                throw Self.error(failure)
            }
        }
    }

    static func isUnsupported(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL
    }

    private static func error(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
