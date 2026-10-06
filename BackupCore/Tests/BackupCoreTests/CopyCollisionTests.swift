import Darwin
import Foundation
import Testing
@testable import BackupCore

/// Copying never writes over anything and never writes through a link: every item it makes is new. Whatever is already
/// at a target — an earlier step's file, a link, a folder, or an item of the same copy whose name the destination does
/// not tell apart — stops the copy with an error that names it, and stays as it was.
struct CopyCollisionTests {
    private let temp: TempDirectory
    private let date = Fixtures.date("2026-09-28 14:30:00")

    init() throws {
        temp = try TempDirectory()
    }

    private func listing(_ root: URL, excludes: [String] = []) throws -> PayloadListing {
        try PayloadWalker().listing(of: Payload(root: root, excludes: excludes, collectedAt: date))
    }

    private func copy(_ root: URL, into copy: URL, afterEachItem: @escaping (String) -> Void = { _ in }) throws {
        let listing = try listing(root)
        try PayloadCopier().copy(listing, into: copy.path, afterEachItem: afterEachItem).check(in: copy.path)
    }

    private func content(_ relative: String) -> String? {
        (try? Data(contentsOf: temp.path(relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    private func collision(_ error: any Error) -> String? {
        guard case let .collisionInCopy(path) = error as? DestinationError else { return nil }
        return path
    }

    @Test func fileAlreadyInTheFolderIsNotWrittenOver() throws {
        defer { temp.remove() }
        try temp.file("vault/x.txt", "from the source")
        try temp.file("out/x.txt", "from an earlier step")

        #expect(throws: DestinationError.collisionInCopy(temp.path("out/x.txt").path)) {
            try copy(temp.path("vault"), into: temp.path("out"))
        }
        #expect(content("out/x.txt") == "from an earlier step")
    }

    @Test func linkAlreadyInTheFolderIsNotWrittenThrough() throws {
        defer { temp.remove() }
        try temp.file("vault/docs/n.txt", "from the source")
        try temp.file("user/docs/n.txt", "the person's own")
        try temp.directory("out")
        try FileManager.default.createSymbolicLink(atPath: temp.path("out/docs").path, withDestinationPath: temp.path("user/docs").path)

        #expect(throws: DestinationError.collisionInCopy(temp.path("out/docs").path)) {
            try copy(temp.path("vault"), into: temp.path("out"))
        }
        #expect(content("user/docs/n.txt") == "the person's own")
        #expect(temp.names(in: "user/docs") == ["n.txt"])
    }

    @Test func folderAlreadyInTheFolderIsNotMergedInto() throws {
        defer { temp.remove() }
        try temp.file("vault/docs/n.txt", "from the source")
        try temp.file("out/docs/m.txt", "from an earlier step")

        #expect(throws: DestinationError.collisionInCopy(temp.path("out/docs").path)) {
            try copy(temp.path("vault"), into: temp.path("out"))
        }
        #expect(temp.names(in: "out/docs") == ["m.txt"])
    }

    @Test func itemPlantedWhileCopyingIsNeitherWrittenOverNorFollowed() throws {
        defer { temp.remove() }
        let names = ["a.txt", "b.txt"]
        for name in names { try temp.file("vault/docs/\(name)", "from the source") }
        let secret = try temp.file("user/secret.txt", "the person's own")
        let docs = temp.path("out/docs").path
        try temp.directory("out")
        var planted: [String] = []

        let error = #expect(throws: DestinationError.self) {
            try copy(temp.path("vault"), into: temp.path("out")) { _ in
                for name in names where !FileManager.default.fileExists(atPath: docs + "/" + name) {
                    symlink(secret.path, docs + "/" + name)
                    planted.append(name)
                }
            }
        }
        #expect(planted.count == 1)
        #expect(error.flatMap(collision) == docs + "/" + (planted.first ?? ""))
        #expect(content("user/secret.txt") == "the person's own")
    }

    @Test func excludedNameLeavesAFolderThatWasAlreadyThere() throws {
        defer { temp.remove() }
        try temp.file("vault/a.txt", "a")
        try temp.file("vault/cache/c.bin", "c")
        try temp.directory("out/cache")

        try PayloadCopier().copy(try listing(temp.path("vault"), excludes: ["cache"]), into: temp.path("out").path)

        #expect(temp.names(in: "out") == ["a.txt", "cache"])
    }

    @Test func namesThatDifferOnlyInCaseCollideInTheCopy() throws {
        let disk = try DiskImage(.caseSensitiveAPFS, name: "TEST-BE-CASE")
        defer {
            disk.detach()
            temp.remove()
        }
        for (relative, text) in [("top/A.txt", "upper"), ("top/a.txt", "lower"), ("deep/sub/B.txt", "upper"), ("deep/sub/b.txt", "lower"),
                                 ("folders/Docs/x.txt", "upper"), ("folders/docs/y.txt", "lower")] {
            let file = disk.root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        for (tree, folder) in [("top", ""), ("deep", "/sub"), ("folders", "")] {
            let target = try temp.directory("copy-\(tree)")
            let error = #expect(throws: DestinationError.self) { try copy(disk.root.appendingPathComponent(tree), into: target) }
            let path = try #require(error.flatMap(collision))
            #expect((path as NSString).deletingLastPathComponent == target.path + folder)
        }
        #expect(temp.names(in: "copy-top").count == 1)
        #expect(["upper", "lower"].contains(content("copy-top/" + temp.names(in: "copy-top")[0])))
        #expect(temp.names(in: "copy-deep/sub").count == 1)
    }

    @Test func checkFindsTwoListedItemsThatAreOneItemInTheCopy() throws {
        let disk = try DiskImage(.caseSensitiveAPFS, name: "TEST-BE-CASE")
        defer {
            disk.detach()
            temp.remove()
        }
        let pair = disk.root.appendingPathComponent("pair")
        try FileManager.default.createDirectory(at: pair, withIntermediateDirectories: false)
        for name in ["A.txt", "a.txt"] {
            try Data("same".utf8).write(to: pair.appendingPathComponent(name))
        }
        let listing = try listing(pair)
        try temp.file("copy/a.txt", "same")

        let error = #expect(throws: DestinationError.self) { try WrittenCopy(listing: listing, written: Set(listing.entries.map(\.relativePath))).check(in: temp.path("copy").path) }
        #expect(error.flatMap(collision).map { ($0 as NSString).deletingLastPathComponent } == temp.path("copy").path)
    }

    @Test func collisionIsToldInPlainWords() {
        #expect(DestinationError.collisionInCopy("/d/a.md").localizedDescription
            == "“/d/a.md” already exists in the copy, so nothing was written over it: two originals have names the destination does not tell apart (such as names that differ only in letter case), or something was already there. The copy was left unfinished so as not to pass for a complete one.")
    }
}
