import Darwin
import Foundation

/// The system reports such a name as an illegal byte sequence (`EILSEQ`).
public enum DirectoryNamesError: Error, Equatable, LocalizedError {
    case undecodableName(folder: String)

    public var errorDescription: String? {
        switch self {
        case let .undecodableName(folder):
            "A file name in “\(folder)” is not valid UTF-8 (written by another system or a damaged disk), so it can’t be read or copied faithfully. Rename it."
        }
    }
}

/// Every name in a folder. Foundation leaves out names starting with “._” even where they are ordinary files of the person.
/// A name whose bytes are not valid UTF-8 cannot be told apart or reached again by its path, so it is never passed on.
enum DirectoryNames {
    /// Fails before returning anything when a name is not valid UTF-8.
    static func of(_ path: String) throws -> [String] {
        try read(path) { throw DirectoryNamesError.undecodableName(folder: path) }
    }

    /// For estimates only: names that are not valid UTF-8 are left out.
    static func decodable(in path: String) throws -> [String] {
        try read(path) {}
    }

    private static func read(_ path: String, onUndecodable: () throws -> Void) throws -> [String] {
        guard let directory = opendir(path) else { throw currentError() }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { break }
            let bytes = withUnsafeBytes(of: entry.pointee.d_name) { Array($0.prefix(Int(entry.pointee.d_namlen))) }
            let name = String(decoding: bytes, as: UTF8.self)
            guard name.utf8.elementsEqual(bytes) else {
                try onUndecodable()
                continue
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
