import Darwin
import Foundation

/// An external disk lives at `/Volumes/<Name>` only while it is mounted. After an unclean disconnect an ordinary folder
/// of the same name can stay there on the system disk; anything written into it would fill the system disk instead.
public struct VolumeMounts: Sendable {
    private let volumesRoot: String

    public init(volumesRoot: String = "/Volumes") {
        self.volumesRoot = volumesRoot
    }

    /// False when the path lies in `<volumesRoot>/<Name>` and no volume is mounted there.
    /// A link there (“Macintosh HD” points at the system disk) leads to a real volume and counts as mounted.
    public func isOnMountedVolume(_ url: URL) -> Bool {
        let base = URL(fileURLWithPath: volumesRoot).standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count > base.count,
              zip(base, components).allSatisfy({ $0.lowercased() == $1.lowercased() }) else { return true }
        let volume = NSString.path(withComponents: Array(components.prefix(base.count + 1)))
        var volumeInfo = stat()
        var rootInfo = stat()
        guard lstat(volume, &volumeInfo) == 0, stat(volumesRoot, &rootInfo) == 0 else { return false }
        return volumeInfo.st_mode & S_IFMT == S_IFLNK || volumeInfo.st_dev != rootInfo.st_dev
    }
}
