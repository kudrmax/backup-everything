import Darwin
import Foundation
import Testing
@testable import BackupCore

/// FAT keeps names in UTF-16 and may hold a lone surrogate (written by another system or a damaged disk); macOS lists
/// such a name as bytes that are not UTF-8 and cannot be reached by them. Nothing is done to a folder with such a name.
struct UndecodableNameTests {
    private let disk: DiskImage
    private let tree: URL

    init() throws {
        disk = try DiskImage(.fat16, name: "TEST-BE-SUR", raw: true)
        tree = disk.root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("sibling".utf8).write(to: tree.appendingPathComponent("sibling.txt"))
        try Data("inner".utf8).write(to: tree.appendingPathComponent("sub/inner.txt"))
        try Data("odd".utf8).write(to: tree.appendingPathComponent("TBEaaaa"))
        try disk.patch(Array("TBEaa".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }), with: [0x54, 0, 0x42, 0, 0x00, 0xD8, 0x61, 0, 0x61, 0])
    }

    @Test func listingNamesTheFolder() throws {
        #expect(throws: DirectoryNamesError.undecodableName(folder: tree.path)) { try DirectoryNames.of(tree.path) }
        let error = DirectoryNamesError.undecodableName(folder: tree.path)
        #expect(error.localizedDescription.contains("“\(tree.path)” is not valid UTF-8"))
        #expect(try DirectoryNames.decodable(in: tree.path).sorted() == ["sibling.txt", "sub"])
    }

    @Test func sourceWithSuchANameIsNotCollected() throws {
        #expect(throws: DirectoryNamesError.undecodableName(folder: tree.path)) {
            try PayloadWalker().entries(of: Payload(root: disk.root, collectedAt: Date()))
        }
    }

    @Test func removalDeletesNothingInThatFolder() throws {
        #expect(throws: DirectoryNamesError.undecodableName(folder: tree.path)) { try FolderRemoval().remove(tree.path) }
        #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent("sibling.txt").path))
        #expect(FileManager.default.fileExists(atPath: tree.appendingPathComponent("sub/inner.txt").path))
    }

    @Test func usageCountsTheRestOnce() throws {
        let counted = ["tree/sibling.txt", "tree/sub/inner.txt"].map { FileSpace(path: disk.root.appendingPathComponent($0).path)!.allocatedBytes }
        #expect(try DestinationUsage().bytes(under: disk.root) == counted.reduce(0, +))
    }
}
