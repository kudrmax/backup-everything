import Foundation

/// A small disk of its own file system for one test: attached out of Finder's sight, detached when the test is over.
final class DiskImage: @unchecked Sendable {
    enum Format: String {
        case apfs = "APFS"
        case caseSensitiveAPFS = "Case-sensitive APFS"
        case exFAT = "ExFAT"
        case fat32 = "MS-DOS FAT32"
        case fat16 = "MS-DOS FAT16"
        case hfs = "HFS+"
    }

    let root: URL
    private let folder: TempDirectory
    private let image: URL
    private var device: String?

    /// `mountpoint`: an existing empty folder to mount the disk at, for a disk inside another folder.
    /// `name`: only made-up names, never one of a real disk: a running copy of the app would take it for its own.
    /// `raw`: the image file holds the disk byte for byte, so that `patch` can write what the file system itself refuses to.
    init(_ format: Format, at mountpoint: URL? = nil, name: String = "TEST-BE", raw: Bool = false) throws {
        precondition(name.hasPrefix("TEST-BE"), "Disk images in tests get made-up names only")
        folder = try TempDirectory()
        image = folder.path(raw ? "disk.dmg" : "disk.sparseimage")
        root = try mountpoint ?? folder.directory("volume")
        let type = raw ? ["-type", "UDIF", "-size", "16m"] : ["-type", "SPARSE", "-size", "64m"]
        try Self.hdiutil(["create", "-quiet"] + type + ["-fs", format.rawValue, "-volname", name, "-layout", "NONE", image.path])
        try attach()
    }

    /// Replaces the only occurrence of `bytes` on the disk of a raw image while it is detached, then attaches it again.
    func patch(_ bytes: [UInt8], with replacement: [UInt8]) throws {
        precondition(bytes.count == replacement.count)
        detach()
        var data = try Data(contentsOf: image)
        guard let range = data.firstRange(of: Data(bytes)) else { throw POSIXError(.ENOENT) }
        data.replaceSubrange(range, with: replacement)
        try data.write(to: image)
        try attach()
    }

    /// The same disk is connected again after `detach()`.
    func attach() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
