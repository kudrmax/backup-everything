import Darwin
import Foundation

/// The size of a file as its readers see it; for a file kept compressed by APFS, the size of its unpacked data.
struct LogicalSize {
    func of(_ path: String) throws -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int64(info.st_size)
    }

    /// A copy whose size differs from an original that kept its size while it was copied is broken.
    /// An original that changed meanwhile (a live file) explains the difference: the copy holds what was read.
    func checkCopy(_ target: String, of source: String, sizeBefore: Int64) throws {
        let copied = try of(target)
        guard copied != sizeBefore, try of(source) == sizeBefore else { return }
        throw DestinationError.copyMismatch(path: source, expected: sizeBefore, actual: copied)
    }
}
