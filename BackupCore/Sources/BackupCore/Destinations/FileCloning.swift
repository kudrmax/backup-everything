import Darwin
import Foundation

public protocol FileCloning: Sendable {
    func isSupported(at folder: URL) -> Bool
    func clone(_ original: URL, to target: URL) throws
}

public struct APFSCloning: FileCloning {
    public init() {}

    public func isSupported(at folder: URL) -> Bool {
        (try? folder.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning) == true
    }

    public func clone(_ original: URL, to target: URL) throws {
        guard clonefile(original.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
