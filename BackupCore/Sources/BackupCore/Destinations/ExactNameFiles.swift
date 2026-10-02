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

    private func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
