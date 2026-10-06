import Darwin
import Foundation

/// Every name in a folder. Foundation leaves out names starting with “._” even where they are ordinary files of the person.
enum DirectoryNames {
    static func of(_ path: String) throws -> [String] {
        guard let directory = opendir(path) else { throw currentError() }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { break }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                FileManager.default.string(withFileSystemRepresentation: bytes.baseAddress!.assumingMemoryBound(to: CChar.self), length: Int(entry.pointee.d_namlen))
            }
            if name != "." && name != ".." { names.append(name) }
        }
        guard errno == 0 else { throw currentError() }
        return names
    }

    private static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
