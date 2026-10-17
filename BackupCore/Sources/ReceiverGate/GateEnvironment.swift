import Foundation

public protocol GateEnvironment {
    var currentUID: uid_t { get }
    func ownerUID(ofPath path: String) -> uid_t?
    func volumeHonoursOwners(atPath path: String) -> Bool
    func fileExists(atPath path: String) -> Bool
    func realPath(ofPath path: String) -> String?
}

public struct SystemGateEnvironment: GateEnvironment {
    public init() {}

    public var currentUID: uid_t { geteuid() }

    public func ownerUID(ofPath path: String) -> uid_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_uid
    }

    public func volumeHonoursOwners(atPath path: String) -> Bool {
        var volume = statfs()
        guard statfs(path, &volume) == 0 else { return false }
        return volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0
    }

    public func fileExists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    public func realPath(ofPath path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
