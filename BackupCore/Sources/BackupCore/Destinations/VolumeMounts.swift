import Darwin
import Foundation

/// An external disk lives at `/Volumes/<Name>` only while it is mounted. After an unclean disconnect an ordinary folder
/// of the same name can stay there on the system disk; anything written into it would fill the system disk instead.
public struct VolumeMounts: Sendable {
    private let volumesRoot: String

    public init(volumesRoot: String = "/Volumes") {
        self.volumesRoot = volumesRoot
    }

    /// False when the path leads into `<volumesRoot>/<Name>` and no volume is mounted there. Where the path leads is found
    /// by following its links, so another spelling (`/System/Volumes/Data/Volumes/…`, another letter case) or a link to
    /// the folder is caught too; a link in `<volumesRoot>` (“Macintosh HD” points at the system disk) leads to a real volume.
    public func isOnMountedVolume(_ url: URL) -> Bool {
        guard let root = identity(of: volumesRoot) else { return true }
        let components = resolved(url.path).pathComponents
        for count in 1..<max(components.count, 1) where identity(of: path(components.prefix(count))) == root {
            var volume = stat()
            guard lstat(path(components.prefix(count + 1)), &volume) == 0 else { return false }
            return volume.st_dev != root.device
        }
        return true
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private func identity(of path: String) -> Identity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    /// The path with every link followed. Of a path that does not exist, the existing beginning is followed.
    private func resolved(_ path: String) -> URL {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        for count in stride(from: components.count, through: 1, by: -1) {
            guard let real = realpath(self.path(components.prefix(count)), nil) else { continue }
            defer { free(real) }
            return components.dropFirst(count).reduce(URL(fileURLWithPath: String(cString: real))) { $0.appendingPathComponent($1) }
        }
        return URL(fileURLWithPath: path)
    }

    private func path(_ components: ArraySlice<String>) -> String {
        NSString.path(withComponents: Array(components))
    }
}
