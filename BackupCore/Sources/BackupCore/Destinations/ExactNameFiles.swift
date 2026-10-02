import Darwin
import Foundation

/// Creates files and folders under the exact names given. `URL` and `FileManager` decompose Unicode in names
/// (“й” becomes “и” plus a combining breve), so a copy made through them would differ from the original byte for byte.
struct ExactNameFiles {
    func createDirectories(_ relativePath: String, in base: String) throws {
        var path = base
        for component in relativePath.split(separator: "/") {
            path += "/" + component
            if mkdir(path, 0o755) != 0 && errno != EEXIST { throw currentError() }
        }
    }

    /// Copies a file or a symbolic link together with its dates, permissions, flags and extended attributes.
    func copy(_ source: String, to target: String) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)
        if copyfile(source, target, nil, flags) != 0 { throw currentError() }
    }

    /// Gives an existing item the dates, permissions, flags and extended attributes of `source`, dropping its own.
    /// The item's lock is lifted first: a clone of a locked file is locked too.
    func copyMetadata(_ source: String, to target: String) throws {
        var info = stat()
        guard lstat(target, &info) == 0 else { throw currentError() }
        if info.st_flags != 0 && lchflags(target, 0) != 0 { throw currentError() }
        let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)
        if copyfile(source, target, nil, flags) != 0 { throw currentError() }
    }

    private func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
