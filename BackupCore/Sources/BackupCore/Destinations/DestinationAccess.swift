import Darwin
import Foundation

public enum DestinationReadiness: Equatable, Sendable {
    case ready
    case folderMissing
    case notOwnedByBackupAccount(owner: String)
    case volumeIgnoresOwners
    case accountMissing
    case ancestorNotTraversable(path: String)
}

public protocol DestinationAccess: Sendable {
    func readiness(of root: URL) -> DestinationReadiness
}

/// A destination is usable only where the file system itself keeps the app out: the root belongs to the backup account
/// on a volume that honours owners (external disks ignore them until `diskutil enableOwnership`), and the account can
/// reach it through every folder above it.
public struct SystemDestinationAccess: DestinationAccess {
    public static let roleAccount = "_backupeverything"

    private let roleAccount: String

    public init(roleAccount: String = SystemDestinationAccess.roleAccount) {
        self.roleAccount = roleAccount
    }

    public func readiness(of root: URL) -> DestinationReadiness {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .folderMissing }
        guard let account = getpwnam(roleAccount) else { return .accountMissing }
        var volume = statfs()
        guard statfs(root.path, &volume) == 0, volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else { return .volumeIgnoresOwners }
        if let blocked = untraversableAncestor(of: root, uid: account.pointee.pw_uid, gid: account.pointee.pw_gid) {
            return .ancestorNotTraversable(path: blocked)
        }
        guard info.st_uid == account.pointee.pw_uid else {
            let owner = getpwuid(info.st_uid).map { String(cString: $0.pointee.pw_name) } ?? String(info.st_uid)
            return .notOwnedByBackupAccount(owner: owner)
        }
        return .ready
    }

    static func canTraverse(mode: mode_t, owner: uid_t, group: gid_t, uid: uid_t, gid: gid_t) -> Bool {
        uid == 0 || owner == uid || mode & S_IXOTH != 0 || (mode & S_IXGRP != 0 && group == gid)
    }

    /// The nearest folder above the root that the account cannot pass, on the root's real path.
    private func untraversableAncestor(of root: URL, uid: uid_t, gid: gid_t) -> String? {
        var ancestor = (root.resolvingSymlinksInPath().path as NSString).deletingLastPathComponent
        while true {
            var info = stat()
            guard stat(ancestor, &info) == 0 else { return ancestor }
            if !Self.canTraverse(mode: info.st_mode, owner: info.st_uid, group: info.st_gid, uid: uid, gid: gid) { return ancestor }
            guard ancestor != "/" else { return nil }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }
}

/// For tests and the sandbox: any existing folder is ready.
public struct AlwaysReadyAccess: DestinationAccess {
    public init() {}

    public func readiness(of root: URL) -> DestinationReadiness {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue ? .ready : .folderMissing
    }
}
