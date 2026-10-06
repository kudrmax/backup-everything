import Darwin
import Foundation

/// How much disk space a folder really takes, as the file system reports it: data shared by APFS clones is counted once.
public struct DestinationUsage {
    public init() {}

    public func bytes(under root: URL) throws -> Int64 {
        guard (try? DirectoryNames.of(root.path)) != nil else { throw DestinationError.unavailable }
        var total: Int64 = 0
        var countedClones: Set<UInt64> = []
        add(root.path, to: &total, countedClones: &countedClones)
        return total
    }

    /// Folders that cannot be read are skipped: the size is an estimate for showing.
    private func add(_ directory: String, to total: inout Int64, countedClones: inout Set<UInt64>) {
        for name in (try? DirectoryNames.of(directory)) ?? [] {
            let path = directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                add(path, to: &total, countedClones: &countedClones)
            case S_IFREG:
                guard let space = FileSpace(path: path) else { continue }
                if let clone = space.clone {
                    total += clone.privateBytes
                    if countedClones.insert(clone.id).inserted {
                        total += space.allocatedBytes - clone.privateBytes
                    }
                } else {
                    total += space.allocatedBytes
                }
            default:
                continue
            }
        }
    }
}

/// Space a file occupies on disk. `clone` is set when the file may share blocks with its clones: those share one id,
/// and only `privateBytes` belong to this file alone.
struct FileSpace {
    let allocatedBytes: Int64
    let clone: (id: UInt64, privateBytes: Int64)?

    private static let cloneAttributes = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        | attrgroup_t(ATTR_CMNEXT_CLONEID)
        | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)

    init?(path: String) {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        request.forkattr = Self.cloneAttributes
        var buffer = [UInt8](repeating: 0, count: 128)
        let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS)
        guard getattrlist(path, &request, &buffer, buffer.count, options) == 0 else { return nil }

        let values = buffer.withUnsafeBytes { raw in
            var offset = MemoryLayout<UInt32>.size
            func next<Value>(_: Value.Type) -> Value {
                defer { offset += MemoryLayout<Value>.size }
                return raw.loadUnaligned(fromByteOffset: offset, as: Value.self)
            }
            return (
                returned: next(attribute_set_t.self),
                allocated: next(Int64.self),
                privateSize: next(Int64.self),
                cloneID: next(UInt64.self),
                flags: next(UInt64.self)
            )
        }
        allocatedBytes = values.allocated
        let mayShare = values.returned.forkattr & Self.cloneAttributes == Self.cloneAttributes
            && values.flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
        clone = mayShare ? (values.cloneID, min(values.privateSize, values.allocated)) : nil
    }
}
