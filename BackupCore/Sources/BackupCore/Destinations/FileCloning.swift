import Darwin
import Foundation

public protocol FileCloning: Sendable {
    func isSupported(at folder: URL) -> Bool
    func clone(_ original: URL, to targetPath: String) throws
}

public struct APFSCloning: FileCloning {
    public init() {}

    public func isSupported(at folder: URL) -> Bool {
        (try? folder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning) == true
    }

    public func clone(_ original: URL, to targetPath: String) throws {
        guard clonefile(original.path, targetPath, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
