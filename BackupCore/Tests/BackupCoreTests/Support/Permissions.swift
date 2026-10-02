import Darwin
import Foundation
@testable import BackupCore

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

    static func denyDeleting(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone deny delete,delete_child", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw POSIXError(.EPERM) }
    }

    static func accessList(of url: URL) -> String? {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    /// Removes a test folder whatever locks, permissions and access lists its items carry.
    static func removeTree(_ url: URL) {
        try? FolderRemoval().remove(url.path)
    }
}
