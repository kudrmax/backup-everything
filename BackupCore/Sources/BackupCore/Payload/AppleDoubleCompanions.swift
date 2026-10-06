import Darwin
import Foundation

/// A disk without extended attributes of its own (exFAT, FAT, some network shares) keeps those of “x” in a file “._x” beside
/// it. Such a companion is read and written through “x”; listed as a file, it would be copied twice and clash with “x”.
enum AppleDoubleCompanions {
    private static let prefix = "._"

    /// The names without the companions of other names in the folder. Where the disk has extended attributes of its own,
    /// or the companion has no “x”, a “._” name is a file like any other.
    static func leftOut(of names: [String], in directory: String) -> [String] {
        guard names.contains(where: { $0.hasPrefix(prefix) }), !keepsAttributesItself(directory) else { return names }
        let others = Set(names.map(folded))
        return names.filter { name in
            !(name.hasPrefix(prefix) && others.contains(folded(String(name.dropFirst(prefix.count)))))
        }
    }

    /// When it cannot be told, nothing is left out: a file too many is better than a file lost.
    private static func keepsAttributesItself(_ path: String) -> Bool {
        var volume = statfs()
        guard statfs(path, &volume) == 0 else { return true }
        let mountPoint = withUnsafeBytes(of: volume.f_mntonname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        var buffer = [UInt8](repeating: 0, count: MemoryLayout<UInt32>.size + MemoryLayout<vol_capabilities_attr_t>.size)
        guard getattrlist(mountPoint, &request, &buffer, buffer.count, 0) == 0 else { return true }
        let capabilities = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size, as: vol_capabilities_attr_t.self) }
        let attributes = UInt32(VOL_CAP_INT_EXTENDED_ATTR)
        return capabilities.valid.1 & attributes == 0 || capabilities.capabilities.1 & attributes != 0
    }

    private static func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
