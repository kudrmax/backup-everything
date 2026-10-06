import Darwin
import Foundation

/// The file system of the disk a folder is on. Copies are kept only on APFS: it keeps everything a Mac file has, and
/// copies share unchanged files there. Other disks (exFAT, FAT, Mac OS Extended, network shares) are not used at all.
public struct DiskFormat: Equatable, Sendable {
    private static let names = [
        "apfs": "APFS",
        "exfat": "exFAT",
        "msdos": "FAT",
        "hfs": "Mac OS Extended (HFS+)",
        "smbfs": "a network share (SMB)",
        "afpfs": "a network share (AFP)",
        "nfs": "a network share (NFS)",
        "webdav": "a network share (WebDAV)",
    ]

    public let volumeName: String
    /// The kernel's name of the file system, such as `apfs` or `exfat`.
    public let fileSystem: String

    public init(volumeName: String, fileSystem: String) {
        self.volumeName = volumeName
        self.fileSystem = fileSystem
    }

    /// The disk of the folder, or of its nearest existing parent; nil when not even that can be read.
    public static func of(_ url: URL) -> DiskFormat? {
        var path = url.standardizedFileURL.path
        var volume = statfs()
        while statfs(path, &volume) != 0 {
            guard errno == ENOENT, path != "/" else { return nil }
            path = (path as NSString).deletingLastPathComponent
        }
        let mountPoint = withUnsafeBytes(of: volume.f_mntonname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        let fileSystem = withUnsafeBytes(of: volume.f_fstypename) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        let mount = URL(fileURLWithPath: mountPoint, isDirectory: true)
        let name = (try? mount.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? mount.lastPathComponent
        return DiskFormat(volumeName: name, fileSystem: fileSystem)
    }

    public var isSupported: Bool {
        fileSystem == "apfs"
    }

    public var displayName: String {
        Self.names[fileSystem] ?? fileSystem
    }

    public static func problem(name: String, format: String) -> String {
        "Disk “\(name)” is formatted as \(format) and can’t be used. Backups need APFS: reformat it in Disk Utility (this erases it)."
    }
}
