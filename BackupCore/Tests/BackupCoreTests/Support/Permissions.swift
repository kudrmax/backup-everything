import Darwin
import Foundation

/// Finder locks, permissions and extended attributes of test files.
enum Permissions {
    static func lock(_ url: URL) throws {
        guard chflags(url.path, UInt32(UF_IMMUTABLE)) == 0 else { throw POSIXError(.EPERM) }
    }

    static func unlockTree(_ root: URL) {
        chflags(root.path, 0)
        chmod(root.path, 0o755)
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return }
        while let relative = enumerator.nextObject() as? String {
            let path = root.path + "/" + relative
            lchflags(path, 0)
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                chmod(path, 0o755)
            }
        }
    }

    static func setAttribute(_ name: String, value: String, on url: URL) throws {
        let data = Array(value.utf8)
        guard setxattr(url.path, name, data, data.count, 0, XATTR_NOFOLLOW) == 0 else { throw POSIXError(.EIO) }
    }

    static func attribute(_ name: String, of url: URL) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = getxattr(url.path, name, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        guard length >= 0 else { throw POSIXError(.ENOATTR) }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }
}
