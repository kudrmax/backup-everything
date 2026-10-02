import Darwin
import Foundation

/// Files kept by APFS transparent compression: the data lives in the `com.apple.decmpfs` attribute and the resource fork,
/// the file carries the `UF_COMPRESSED` flag and its ordinary data is empty.
enum Compression {
    static let sample = String(repeating: "compress me ", count: 20_000)

    static func write(_ content: String, compressedAt target: URL) throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
        try Data(content.utf8).write(to: plain)
        defer { try? FileManager.default.removeItem(at: plain) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["--hfsCompression", plain.path, target.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, isCompressed(target) else { throw POSIXError(.ENOTSUP) }
    }

    static func isCompressed(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & UInt32(UF_COMPRESSED) != 0
    }
}
