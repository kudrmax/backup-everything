import Darwin
import Foundation
import Testing
@testable import BackupCore

/// Sources may be on any disk (a camera card on FAT, a stick on exFAT): their files arrive in the work folder on APFS with
/// what those disks keep of them.
struct ForeignFileSystemTests {
    private let temp: TempDirectory
    private let first = Fixtures.date("2026-09-01 10:00:00")
    private let tags = "com.apple.metadata:_kMDItemUserTags"

    init() throws {
        temp = try TempDirectory()
    }

    private func copy(_ payload: Payload) throws -> URL {
        let target = try temp.directory("ssd/copy")
        try PayloadCopier().copy(try PayloadWalker().listing(of: payload), into: target.path).check(in: target.path)
        return target
    }

    // MARK: Sources on other disks

    /// Without extended attributes of their own, these disks keep those of “x” in a companion file “._x”: it is metadata that
    /// travels with “x”, not a file of the person. A “._” name without its “x” is a file like any other.
    @Test(arguments: [DiskImage.Format.exFAT, .fat32])
    func sourceOnADiskWithoutAttributesArrivesWhole(_ format: DiskImage.Format) throws {
        defer { Permissions.removeTree(temp.url) }
        let disk = try DiskImage(format)
        let vault = disk.root.appendingPathComponent("vault")
        let notes = vault.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let note = notes.appendingPathComponent("b.md")
        try Data("beta".utf8).write(to: note)
        try Data("orphan".utf8).write(to: vault.appendingPathComponent("._orphan"))
        try Permissions.setAttribute(tags, value: "Red", on: note)
        try Permissions.setAttribute(tags, value: "Blue", on: notes)
        #expect(Set(try DirectoryNames.of(notes.path)).isSuperset(of: ["b.md", "._b.md"]), "the companion is a file of its own here")
        let payload = Payload(root: vault, collectedAt: first)
        #expect(try PayloadWalker().entries(of: payload).map(\.relativePath) == ["._orphan", "notes", "notes/b.md"])

        let stored = try copy(payload)

        #expect(try DirectoryNames.of(stored.appendingPathComponent("notes").path) == ["b.md"])
        #expect(try String(contentsOf: stored.appendingPathComponent("notes/b.md"), encoding: .utf8) == "beta")
        #expect(try Permissions.attribute(tags, of: stored.appendingPathComponent("notes/b.md")) == "Red")
        #expect(try Permissions.attribute(tags, of: stored.appendingPathComponent("notes")) == "Blue")
        #expect(try String(contentsOf: stored.appendingPathComponent("._orphan"), encoding: .utf8) == "orphan")
    }

    /// On APFS a “._x” is an ordinary file of the person even beside “x”, whatever it holds.
    @Test func dotUnderscoreFilesBesideTheirNamesakesOnAPFSAreCopiedAsFiles() throws {
        defer { temp.remove() }
        let appleDouble = Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00] + Array("Mac OS X        ".utf8) + [UInt8](repeating: 0, count: 64))
        try temp.file("vault/foo", "foo")
        try appleDouble.write(to: temp.path("vault/._foo"))
        try temp.file("vault/bar", "bar")
        try temp.file("vault/._bar", "plain user content")

        let stored = try copy(Payload(root: temp.path("vault"), collectedAt: first))

        #expect(try Data(contentsOf: stored.appendingPathComponent("._foo")) == appleDouble)
        #expect(try String(contentsOf: stored.appendingPathComponent("._bar"), encoding: .utf8) == "plain user content")
        #expect(try String(contentsOf: stored.appendingPathComponent("foo"), encoding: .utf8) == "foo")
        #expect(listxattr(stored.appendingPathComponent("foo").path, nil, 0, XATTR_NOFOLLOW) == 0)
    }
}
