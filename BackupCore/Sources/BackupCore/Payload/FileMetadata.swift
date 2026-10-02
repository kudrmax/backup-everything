import Darwin
import Foundation

/// Gives an existing file or folder what a person sees of another one: dates, permissions, Finder lock and hidden flag,
/// access list and extended attributes (tags, labels). Its own data is never touched. APFS keeps a compressed file's data
/// in the `com.apple.decmpfs` attribute and the resource fork, marked by the `UF_COMPRESSED` flag: these stay as they are,
/// since dropping any of them empties the file. So does `com.apple.provenance`, which only the system manages.
struct FileMetadata {
    private static let personalFlags = UInt32(UF_NODUMP | UF_IMMUTABLE | UF_APPEND | UF_OPAQUE | UF_HIDDEN)
    private static let compressedFlag = UInt32(UF_COMPRESSED)
    private static let systemAttributes: Set<String> = ["com.apple.decmpfs", "com.apple.provenance"]

    func apply(from source: String, to target: String) throws {
        let sourceInfo = try status(of: source)
        let targetInfo = try status(of: target)
        let keptCompression = targetInfo.st_flags & Self.compressedFlag
        if targetInfo.st_flags != keptCompression {
            try check(lchflags(target, keptCompression))
        }
        try copyAttributes(from: source, to: target, targetIsCompressed: keptCompression != 0)
        try copyAccessList(from: source, to: target)
        try check(lchmod(target, sourceInfo.st_mode & 0o7777))
        try copyDates(sourceInfo, to: target)
        let flags = (sourceInfo.st_flags & Self.personalFlags) | keptCompression
        if flags != keptCompression {
            try check(lchflags(target, flags))
        }
    }

    /// A compressed target keeps its data in its resource fork, so the source's resource fork cannot be given to it.
    private func copyAttributes(from source: String, to target: String, targetIsCompressed: Bool) throws {
        let kept = targetIsCompressed ? Self.systemAttributes.union([XATTR_RESOURCEFORK_NAME]) : Self.systemAttributes
        let wanted = try attributeNames(of: source)
        if targetIsCompressed && wanted.contains(XATTR_RESOURCEFORK_NAME) { throw POSIXError(.ENOTSUP) }
        for name in try attributeNames(of: target) where !kept.contains(name) {
            try check(removexattr(target, name, XATTR_NOFOLLOW))
        }
        for name in wanted where !kept.contains(name) {
            let value = try attribute(name, of: source)
            try check(value.withUnsafeBytes { setxattr(target, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) })
        }
    }

    private func attributeNames(of path: String) throws -> [String] {
        let names = try read { buffer, size in listxattr(path, buffer, size, XATTR_NOFOLLOW) }
        return names.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private func attribute(_ name: String, of path: String) throws -> [UInt8] {
        try read { buffer, size in getxattr(path, name, buffer, size, 0, XATTR_NOFOLLOW) }
    }

    /// Asks for the size first, then for the bytes.
    private func read(_ call: (UnsafeMutablePointer<CChar>?, Int) -> Int) throws -> [UInt8] {
        let size = call(nil, 0)
        guard size >= 0 else { throw currentError() }
        var buffer = [UInt8](repeating: 0, count: size)
        let length = buffer.withUnsafeMutableBytes { call($0.baseAddress?.assumingMemoryBound(to: CChar.self), size) }
        guard length >= 0 else { throw currentError() }
        return Array(buffer.prefix(length))
    }

    private func copyAccessList(from source: String, to target: String) throws {
        let list = acl_get_link_np(source, ACL_TYPE_EXTENDED) ?? acl_init(0)
        guard let list else { throw currentError() }
        defer { acl_free(UnsafeMutableRawPointer(list)) }
        try check(acl_set_link_np(target, ACL_TYPE_EXTENDED, list))
    }

    private func copyDates(_ source: stat, to target: String) throws {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME)
        var dates = [source.st_birthtimespec, source.st_mtimespec, source.st_atimespec]
        let size = MemoryLayout<timespec>.stride * dates.count
        try check(setattrlist(target, &request, &dates, size, UInt32(FSOPT_NOFOLLOW)))
    }

    private func status(of path: String) throws -> stat {
        var info = stat()
        try check(lstat(path, &info))
        return info
    }

    private func check(_ result: Int32) throws {
        if result != 0 { throw currentError() }
    }

    private func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
