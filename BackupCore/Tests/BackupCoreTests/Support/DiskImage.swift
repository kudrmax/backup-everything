import Foundation

/// A small disk of its own file system for one test: attached out of Finder's sight, detached when the test is over.
final class DiskImage: @unchecked Sendable {
    enum Format: String {
        case apfs = "APFS"
        case exFAT = "ExFAT"
        case fat32 = "MS-DOS FAT32"
    }

    let root: URL
    private let folder: TempDirectory
    private var device: String?

    init(_ format: Format) throws {
        folder = try TempDirectory()
        let image = folder.path("disk.sparseimage")
        root = try folder.directory("volume")
        try Self.hdiutil(["create", "-quiet", "-type", "SPARSE", "-size", "64m", "-fs", format.rawValue, "-volname", "TEST", "-layout", "NONE", image.path])
        let output = try Self.hdiutil(["attach", "-nobrowse", "-noverify", "-mountpoint", root.path, image.path])
        device = output.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) }.last { $0.hasPrefix("/dev/disk") }
    }

    deinit {
        detach()
        folder.remove()
    }

    /// The disk is gone, as if it were ejected or unplugged.
    func detach() {
        guard let device else { return }
        self.device = nil
        _ = try? Self.hdiutil(["detach", "-force", "-quiet", device])
    }

    @discardableResult
    private static func hdiutil(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
        return String(decoding: data, as: UTF8.self)
    }
}
