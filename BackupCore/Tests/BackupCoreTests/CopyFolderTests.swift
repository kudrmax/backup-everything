import Foundation
import Testing
@testable import BackupCore

struct CopyFolderTests {
    private let temp = try! TempDirectory()
    private var folder: CopyFolder { CopyFolder(root: temp.url, naming: Fixtures.naming) }

    @Test func listsOnlyDatedFoldersWithTheMarker() throws {
        defer { temp.remove() }
        try temp.file("obsidian/2026-10-07_100000/.complete", "")
        try temp.file("obsidian/2026-10-07_100000/a.md")
        try temp.file("obsidian/2026-10-08_100000/a.md")
        try temp.directory("obsidian/notes")
        try temp.file("obsidian/2026-10-06_100000", "a file, not a folder")
        #expect(try folder.copies(of: "obsidian") == [Fixtures.snapshot("2026-10-07 10:00:00")])
        #expect(try folder.unfinished(of: "obsidian") == [Fixtures.snapshot("2026-10-08 10:00:00")])
        #expect(try folder.newestCopy(of: "obsidian") == Fixtures.snapshot("2026-10-07 10:00:00"))
    }

    @Test func sortsCopiesByDate() throws {
        defer { temp.remove() }
        try temp.file("obsidian/2026-10-08_100000/.complete", "")
        try temp.file("obsidian/2026-10-01_100000/.complete", "")
        #expect(try folder.copies(of: "obsidian").map(\.name) == ["2026-10-01_100000", "2026-10-08_100000"])
    }

    @Test func missingSourceFolderMeansNoCopies() throws {
        defer { temp.remove() }
        #expect(try folder.copies(of: "obsidian") == [])
        #expect(try folder.newestCopy(of: "obsidian") == nil)
    }

    @Test func refusesASlugThatLeadsOutside() throws {
        defer { temp.remove() }
        #expect(throws: DestinationError.invalidFolderName("../x")) { try folder.copies(of: "../x") }
    }

    @Test func urlOfACopy() throws {
        defer { temp.remove() }
        let url = try folder.url(of: Fixtures.snapshot("2026-10-07 10:00:00"), slug: "obsidian")
        #expect(url == temp.url.appendingPathComponent("obsidian/2026-10-07_100000", isDirectory: true))
    }
}
